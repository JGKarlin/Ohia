import Darwin
import Foundation

// Swift imports Darwin's `struct flock` under the same name as flock(2), so
// bind the system call explicitly rather than resolving the structure symbol.
@_silgen_name("flock")
private func systemFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

/// A process-wide exclusive slot backed by a Darwin advisory file lock.
///
/// Each successful acquisition owns an open file descriptor. Closing that
/// descriptor, including when the owning process exits, releases the lock.
public struct ExclusiveModelSlotLock: Sendable {
    public let lockFileURL: URL

    public init(directoryURL: URL) {
        lockFileURL = directoryURL
            .appendingPathComponent("exclusive-model-slot.lock", isDirectory: false)
    }

    /// Attempts to acquire the slot without waiting.
    ///
    /// - Returns: A lease when the slot was acquired, or `nil` when another
    ///   process currently owns it.
    public func tryAcquire() throws -> ExclusiveModelSlotLease? {
        try FileManager.default.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = Darwin.open(
            lockFileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ExclusiveModelSlotLockError(operation: .open, code: errno)
        }

        guard systemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return nil
            }
            throw ExclusiveModelSlotLockError(operation: .acquire, code: lockError)
        }

        return ExclusiveModelSlotLease(
            lockFileURL: lockFileURL,
            fileDescriptor: descriptor
        )
    }
}

public struct ExclusiveModelSlotLockError: Error, Equatable, Sendable, LocalizedError {
    public enum Operation: String, Equatable, Sendable {
        case open
        case acquire
    }

    public let operation: Operation
    public let code: Int32

    public var errorDescription: String? {
        "Could not \(operation.rawValue) exclusive model slot lock "
            + "(POSIX error \(code))."
    }
}

/// Ownership of an acquired exclusive model slot.
///
/// The mutable descriptor is protected by `stateLock`, which makes explicit
/// release safe to call repeatedly or concurrently. Deinitialization is a
/// fallback; callers should release as soon as the model turn ends.
public final class ExclusiveModelSlotLease: @unchecked Sendable {
    public let lockFileURL: URL

    private let stateLock = NSLock()
    private var fileDescriptor: Int32?

    fileprivate init(lockFileURL: URL, fileDescriptor: Int32) {
        self.lockFileURL = lockFileURL
        self.fileDescriptor = fileDescriptor
    }

    public var isHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fileDescriptor != nil
    }

    /// Releases the slot. Calling this more than once has no effect.
    public func release() {
        stateLock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = nil
        stateLock.unlock()

        guard let descriptor else { return }
        _ = systemFlock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    deinit {
        release()
    }
}
