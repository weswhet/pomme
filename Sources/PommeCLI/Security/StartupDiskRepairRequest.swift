import Foundation

/// Bounded input for the Recovery-only startup-disk repair operation. The
/// caller passes the encoded value as the payload of a
/// `PommeRecoveryIntegration.repairAgent` transaction; this type does not
/// construct a second guest command or select another execution channel.
struct PommeRecoveryStartupDiskRepairPayload: Codable, Sendable {
    let user: String
    let password: String
    let source: String
    let timeoutSeconds: Int
}

enum PommeRecoveryStartupDiskRepairRequest {
    static func make(
        credential: StartupDiskCredential,
        timeout: TimeInterval
    ) throws -> Data {
        let seconds = Int(timeout.rounded(.down))
        guard !credential.user.isEmpty,
              !credential.password.isEmpty,
              credential.user.utf8.count <= 256,
              credential.source.utf8.count <= 256,
              !credential.user.contains("\0"),
              !credential.password.contains("\0"),
              !credential.source.contains("\0"),
              timeout.isFinite,
              seconds > 0,
              seconds <= 300
        else { throw PommeRecoverySessionError.invalidRequest }

        let payload = PommeRecoveryStartupDiskRepairPayload(
            user: credential.user,
            password: credential.password,
            source: credential.source,
            timeoutSeconds: seconds
        )
        do {
            let data = try JSONEncoder().encode(payload)
            guard data.count <= 16 * 1024 else {
                throw PommeRecoverySessionError.invalidRequest
            }
            return data
        } catch let error as PommeRecoverySessionError {
            throw error
        } catch {
            throw PommeRecoverySessionError.invalidRequest
        }
    }
}
