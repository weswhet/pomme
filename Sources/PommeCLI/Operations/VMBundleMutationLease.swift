import Darwin
import Foundation

/// The stable, process-shared mutation domain for a managed VM.  The lease
/// file is deliberately never unlinked: replacing it could let two processes
/// lock distinct inodes for the same VM name.
final class VMBundleMutationLease: @unchecked Sendable {
  enum Error: LocalizedError, Equatable, Sendable {
    case unsafeLockFile
    case activeMutation(name: String)
    case invalidScope(name: String)
    case releasedScope
    case descriptorTransfer

    var errorDescription: String? {
      switch self {
      case .unsafeLockFile:
        "VM_MUTATION_LEASE_UNSAFE_LOCK_FILE"
      case .activeMutation(let name):
        "VM_MUTATION_IN_PROGRESS name=\(name)"
      case .invalidScope(let name):
        "VM_MUTATION_LEASE_SCOPE_MISMATCH name=\(name)"
      case .releasedScope:
        "VM_MUTATION_LEASE_RELEASED"
      case .descriptorTransfer:
        "VM_MUTATION_LEASE_DESCRIPTOR_TRANSFER_FAILED"
      }
    }
  }

  private let name: String
  private let lockPath: String
  private let descriptor: Int32
  private let stateLock = NSLock()
  private var released = false

  private init(name: String, lockPath: String, descriptor: Int32) {
    self.name = name
    self.lockPath = lockPath
    self.descriptor = descriptor
  }

  deinit { release() }

  static func acquire(name: String) throws -> VMBundleMutationLease {
    let validName = try validateVMName(name)
    let path = try persistentLockPath(name: validName)
    // The base capability belongs only to this process. Explicit supervisor
    // and worker transfer goes through `duplicateDescriptor()`, whose `dup`
    // result intentionally has close-on-exec cleared by Darwin.
    let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw Error.unsafeLockFile }
    guard fchmod(descriptor, 0o600) == 0,
      validates(descriptor: descriptor, path: path)
    else {
      close(descriptor)
      throw Error.unsafeLockFile
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw Error.activeMutation(name: validName)
    }
    return .init(name: validName, lockPath: path, descriptor: descriptor)
  }

  static func acquire(reference: VMReference) throws -> VMBundleMutationLease {
    guard let name = reference.name else { throw Error.unsafeLockFile }
    return try acquire(name: name)
  }

  /// Duplicates the descriptor without changing its lock state.  `flock`
  /// locks are attached to the open file description, so the duplicate is
  /// the only safe capability to pass to a supervisor or worker.
  func duplicateDescriptor() throws -> Int32 {
    try requireActive()
    let duplicate = dup(descriptor)
    guard duplicate >= 0, Self.validates(descriptor: duplicate, path: lockPath) else {
      if duplicate >= 0 { close(duplicate) }
      throw Error.descriptorTransfer
    }
    return duplicate
  }

  /// Installs a duplicate of this lease at a fixed inherited descriptor.
  /// The caller owns the fixed descriptor in its child process; this method
  /// never unlocks the parent lease or closes its original descriptor.
  func installInheritedDescriptor(at fixedDescriptor: Int32) throws {
    guard fixedDescriptor >= 0 else { throw Error.descriptorTransfer }
    try requireActive()
    guard dup2(descriptor, fixedDescriptor) == fixedDescriptor,
      Self.validates(descriptor: fixedDescriptor, path: lockPath)
    else { throw Error.descriptorTransfer }
  }

  /// Verifies that an inherited descriptor is still an owner-only handle to
  /// this VM's persistent mutation domain.  This deliberately does not call
  /// `flock`: probing a descriptor by locking it could acquire a previously
  /// unlocked OFD and therefore turn validation into mutation.
  static func isHeld(descriptor: Int32, for name: String) -> Bool {
    guard let validName = try? validateVMName(name),
      let path = try? persistentLockPath(name: validName)
    else { return false }
    return validates(descriptor: descriptor, path: path)
  }

  /// Proves that an inherited descriptor is not merely a handle to the right
  /// inode, but owns the exclusive mutation lock when this call returns. The
  /// independent probe must first observe contention, while re-locking the
  /// inherited OFD must succeed. A plainly unlocked descriptor is rejected;
  /// production also retains the parent's original OFD across both checks.
  static func isActivelyHeld(descriptor: Int32, for name: String) -> Bool {
    guard let validName = try? validateVMName(name),
      let path = try? persistentLockPath(name: validName),
      validates(descriptor: descriptor, path: path)
    else { return false }

    let probe = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard probe >= 0, validates(descriptor: probe, path: path) else {
      if probe >= 0 { close(probe) }
      return false
    }
    defer { close(probe) }

    if flock(probe, LOCK_EX | LOCK_NB) == 0 {
      _ = flock(probe, LOCK_UN)
      return false
    }
    guard errno == EWOULDBLOCK || errno == EAGAIN else { return false }

    return flock(descriptor, LOCK_EX | LOCK_NB) == 0
  }

  func validates(name: String) -> Bool {
    guard let validName = try? validateVMName(name) else { return false }
    stateLock.lock()
    let active = !released
    stateLock.unlock()
    return active && validName == self.name
      && Self.validates(descriptor: descriptor, path: lockPath)
  }

  func release() {
    stateLock.lock()
    guard !released else {
      stateLock.unlock()
      return
    }
    released = true
    stateLock.unlock()
    // Do not call LOCK_UN here. A supervisor/worker descriptor made with
    // dup/dup2 shares this open file description; LOCK_UN would release
    // its protection prematurely even though that child still owns the
    // transferred capability. Closing only this descriptor lets Darwin
    // release the flock when the final duplicate is closed.
    _ = close(descriptor)
  }

  static func withLease<T>(
    name: String,
    inherited lease: VMBundleMutationLease? = nil,
    _ body: (VMBundleMutationLease) throws -> T
  ) throws -> T {
    if let lease {
      guard lease.validates(name: name) else { throw Error.invalidScope(name: name) }
      return try body(lease)
    }
    let acquired = try acquire(name: name)
    defer { acquired.release() }
    return try body(acquired)
  }

  static func withLease<T>(
    name: String,
    inherited lease: VMBundleMutationLease? = nil,
    _ body: (VMBundleMutationLease) async throws -> T
  ) async throws -> T {
    if let lease {
      guard lease.validates(name: name) else { throw Error.invalidScope(name: name) }
      return try await body(lease)
    }
    let acquired = try acquire(name: name)
    defer { acquired.release() }
    return try await body(acquired)
  }

  private func requireActive() throws {
    stateLock.lock()
    let active = !released
    stateLock.unlock()
    guard active, Self.validates(descriptor: descriptor, path: lockPath) else {
      throw Error.releasedScope
    }
  }

  static func persistentLockPath(name: String) throws -> String {
    try runtimeDirectory()
      .appendingPathComponent("pomme-mutation-\(stableIdentifier(for: name)).lock")
      .path
  }

  private static func validates(descriptor: Int32, path: String) -> Bool {
    guard descriptor >= 0, fcntl(descriptor, F_GETFD) >= 0 else { return false }
    var descriptorStatus = stat()
    guard fstat(descriptor, &descriptorStatus) == 0,
      descriptorStatus.st_mode & S_IFMT == S_IFREG,
      descriptorStatus.st_uid == geteuid(),
      descriptorStatus.st_mode & 0o777 == 0o600,
      descriptorStatus.st_nlink == 1
    else { return false }
    var pathStatus = stat()
    guard lstat(path, &pathStatus) == 0,
      pathStatus.st_mode & S_IFMT == S_IFREG,
      pathStatus.st_dev == descriptorStatus.st_dev,
      pathStatus.st_ino == descriptorStatus.st_ino
    else { return false }
    return true
  }
}
