import Foundation

/// Process entrypoint for the public Pomme command and the one guest-side
/// daemon invocation used by a provisioned VM. The daemon grammar is kept
/// separate from ArgumentParser so a guest launchd job cannot accidentally
/// enter the host command tree.
enum PommeBootstrap {
    static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async {
        if arguments.first == PommeFirstBootProcessRequest.supervisorFlag {
            do {
                guard let request = try PommeFirstBootProcessRequest.parseChildArguments(arguments) else {
                    Foundation.exit(64)
                }
                Foundation.exit(PommeFirstBootProcessIsolation.runSupervisor(request: request))
            } catch {
                Foundation.exit(64)
            }
        }

        if arguments.first == PommeFirstBootProcessRequest.workerFlag {
            do {
                guard let request = try PommeFirstBootProcessRequest.parseChildArguments(arguments) else {
                    Foundation.exit(64)
                }
                Foundation.exit(await PommeCore.runFirstBootProcessChild(request))
            } catch {
                Foundation.exit(64)
            }
        }

        if arguments.first == "--pomme-agent" {
            let exitCode = PommeAgentDaemon.run(arguments: arguments)
            Foundation.exit(exitCode)
        }

        if arguments.first == "--pomme-mdm-staging-helper" {
            Foundation.exit(PommeMDMStagingHelper.run(arguments: arguments))
        }

        if arguments.first == PommeMDMPrivateHelper.flag {
            let exitCode = PommeMDMPrivateHelper.run(arguments: arguments)
            Foundation.exit(exitCode)
        }

        if arguments.first == "--pomme-runtime" {
            let exitCode = await PommeCore.runInternalHelper(arguments: arguments)
            Foundation.exit(exitCode)
        }

        PommeApplication.installDefaultProvisioningServices()
        PommeApplication.installRecoveryIntegrationFactory(
            PommeCore.makeLiveRecoveryIntegrationFactory()
        )

        let publicArguments = PommeCore.normalizedPublicArguments(arguments)
        if publicArguments.contains("--debug") {
            let command = publicArguments.first(where: { !$0.hasPrefix("-") }) ?? "help"
            PommeCore.log("Debug logging enabled for public command \(command).")
        }
        await PommeCLI.main(publicArguments)
    }
}
