import Foundation

/// Builds a template that already carries a prepared owner account, so a VM
/// cloned from it can run an owner-authenticated workflow such as MDM
/// enrollment as its first command.
///
/// The expensive and failure-prone part of reaching that state is creating the
/// owner: an account, a Secure Token, persistent automatic login, and a proven
/// desktop, across several guest boots. Doing it once per template instead of
/// once per VM is the whole point of this command.
///
/// The owner's password is never handed to the caller and is not recorded in
/// the template. A clone recovers it from its own `/etc/kcpassword` through the
/// root agent, because the host Keychain item is scoped to the UUID of the VM
/// this template was captured from and cannot follow the clone.
enum PommeProvisionedTemplate {
    /// Suffix for the disposable VM the template is captured from. It is
    /// created, provisioned, captured, and destroyed inside one command.
    static let provisioningSuffix = "-provisioning"

    /// The capture is taken with System Integrity Protection disabled and the
    /// AMFI override active, which is the state an owner-authenticated
    /// workflow would otherwise have to reach for itself. MDM enrollment
    /// compares the VM against that baseline, finds both already in the state
    /// it needs, and skips the SIP and AMFI child workflows entirely, so a
    /// clone enrolls without a single security mutation.
    ///
    /// Every VM cloned from such a template therefore starts with SIP off. It
    /// is the point of the template, but it is a real posture change and is
    /// recorded in the manifest so `template list` shows it.
    static func create(
        name: String,
        restoreArgs: [String],
        diskSize: String,
        memory: String,
        log: @escaping @Sendable (String) -> Void = { PommeCore.log($0) }
    ) async throws -> [String: Any] {
        let validName = try validateIdentifier(name, kind: .template)
        let bundle = try PommeTemplateStore.bundle(for: validName)
        guard !FileManager.default.fileExists(atPath: bundle.rootURL.path) else {
            throw PommeTemplateError.alreadyExists(validName)
        }
        let vmName = try validateVMName(validName + provisioningSuffix)
        let vmReference = try PommeApplication.namedReference(vmName, requireExists: false)
        guard !FileManager.default.fileExists(atPath: vmReference.bundle.rootURL.path) else {
            throw RunnerError.hostCommandFailed(
                "A VM named \(vmName) already exists; template provisioning needs that name. Delete it explicitly and retry."
            )
        }

        PommeProgressContext.sink?.step(vm: vmName, "Preparing provisioned template")
        log("Creating the disposable VM \(vmName) that template \(validName) is captured from.")
        _ = try await PommeApplication.create(
            name: vmName, restoreArgs: restoreArgs,
            diskSize: diskSize, memory: memory, startMode: .none
        )

        do {
            // Owner preparation only runs as part of a security mutation, so
            // disabling SIP both creates the owner and leaves the posture an
            // enrollment needs. AMFI then follows, which requires SIP already
            // disabled. Both end stopped, which is what the capture needs.
            log("Preparing the owner account and disabling System Integrity Protection on \(vmName).")
            _ = try await PommeApplication.sipWorkflow(
                name: vmName, action: .disable, finalState: .stopped, force: true)
            log("Configuring the AMFI override on \(vmName).")
            _ = try await PommeApplication.amfiWorkflow(
                name: vmName, action: .disable, finalState: .stopped)

            let manifest = try capture(
                from: vmReference, into: bundle, templateName: validName, log: log)
            PommeProgressContext.sink?.step(vm: vmName, "Removing template provisioning VM")
            log("Removing the disposable VM \(vmName).")
            _ = try PommeApplication.destroy(name: vmName)
            return payload(for: manifest, bundle: bundle)
        } catch {
            // The half-built template is never left behind, but the VM is:
            // it holds the owner account and a retained security journal, so
            // deleting it would discard evidence the failure needs.
            try? FileManager.default.removeItem(at: bundle.rootURL)
            let warning = "Template \(validName) was not created. The disposable VM \(vmName) was retained for inspection; delete it with `pomme delete \(vmName) --force`."
            if let sink = PommeProgressContext.sink { sink.warning(warning) }
            else { log(warning) }
            throw error
        }
    }

    /// Clones the stopped VM's disk, NVRAM, and hardware model into the
    /// template bundle. The machine identifier is deliberately not captured:
    /// every VM cloned from the template generates its own, which is what lets
    /// clones run concurrently.
    private static func capture(
        from reference: VMReference,
        into bundle: BundleLayout,
        templateName: String,
        log: @escaping @Sendable (String) -> Void
    ) throws -> PommeTemplateManifest {
        guard try PommeCore.stableVMRunState(reference: reference) == .stopped else {
            throw RunnerError.virtualMachineState(
                "The provisioning VM must be stopped before a template can be captured from it."
            )
        }
        let plan = try PommeCore.securityProvisioningPlan(reference: reference)
        // The VM's own input record carries the restore image it came from,
        // including when it was itself cloned from an installed template, so
        // the captured manifest keeps pointing at the original image.
        let input = try PommeCore.loadProvisioningInput(for: plan)
        let diskSize = input.diskSizeBytes

        PommeProgressContext.sink?.step(vm: reference.displayName, "Capturing template \(templateName)")
        log("Capturing template \(templateName) from the stopped VM.")
        try FileManager.default.createDirectory(
            at: bundle.rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for (source, destination) in [
            (reference.bundle.diskImageURL, bundle.diskImageURL),
            (reference.bundle.auxiliaryStorageURL, bundle.auxiliaryStorageURL),
            (reference.bundle.hardwareModelURL, bundle.hardwareModelURL),
        ] {
            try PommeTemplateStore.clone(source, to: destination)
        }
        let manifest = PommeTemplateManifest(
            name: templateName,
            version: plan.restore.version,
            build: plan.restore.build,
            restoreImageDigest: plan.restore.restoreImageDigest,
            restoreImagePath: input.restoreImagePath,
            diskSizeBytes: diskSize,
            provisionedOwnerAccount: PommeSecurityOwnerIdentity.pomme.username,
            provisionedSecurityDisabled: true
        )
        try PommeTemplateStore.write(manifest, to: bundle)
        return manifest
    }

    private static func payload(
        for manifest: PommeTemplateManifest, bundle: BundleLayout
    ) -> [String: Any] {
        [
            "ok": true,
            "operation": "template-create",
            "hostExitCode": 0,
            "name": manifest.name,
            "version": manifest.version,
            "build": manifest.build,
            "diskSize": manifest.diskSizeBytes,
            "provisioned": true,
            "securityDisabled": manifest.isSecurityDisabled,
            "ownerAccount": manifest.provisionedOwnerAccount as Any,
            "bundlePath": bundle.rootURL.path,
        ]
    }
}
