import Darwin
import Foundation

/// Removes `com.apple.quarantine` from the copy the uninstaller makes of
/// itself. Files in an app installed from a download all carry the
/// attribute, but only the outer app is marked approved when first opened,
/// so a copy of the nested uninstaller would otherwise face Gatekeeper again.
/// Every entry is handled as itself: a symbolic link loses the attribute on
/// the link, and its target is never touched.
public enum QuarantineAttribute {
    public static let name = "com.apple.quarantine"

    public struct Failure: Equatable, Sendable {
        public var url: URL
        public var errorNumber: Int32
    }

    /// Removes the attribute from `root` and everything under it, packages
    /// included. An entry without the attribute is not a failure; any other
    /// error is returned and the rest are still processed.
    public static func removeRecursively(from root: URL) -> [Failure] {
        var failures: [Failure] = []
        var entries = [root]
        // The enumerator lists symbolic links without descending into them.
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                failures.append(Failure(url: url, errorNumber: posixCode(of: error)))
                return true
            })
        while let entry = enumerator?.nextObject() as? URL {
            entries.append(entry)
        }
        for entry in entries {
            let status = entry.withUnsafeFileSystemRepresentation { path in
                path.map { removexattr($0, name, XATTR_NOFOLLOW) } ?? -1
            }
            if status != 0, errno != ENOATTR {
                failures.append(Failure(url: entry, errorNumber: errno))
            }
        }
        return failures
    }

    private static func posixCode(of error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }
}
