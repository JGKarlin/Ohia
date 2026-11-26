import Foundation

public enum OhiaSharedDefaults {
    public static let suiteName = OhiaStorageRoot.appGroupIdentifier

    /// True in a test process, detected as `OhiaLaunchMode` and `JobFetch`
    /// do: Xcode's hosted tests set the XCTest variables or load XCTest;
    /// `swift test` runs XCTest in `xctest`, given the `.xctest` bundle's
    /// path, and Swift Testing in `swiftpm-testing-helper`.
    /// Decided once, before any code reads `store`, so no test, in any order
    /// or in parallel, reaches the user's live preferences.
    public static let usesTestStore: Bool = {
        let process = ProcessInfo.processInfo
        let environment = process.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ["xctest", "swiftpm-testing-helper"].contains(process.processName)
            || process.arguments.contains { $0.hasSuffix(".xctest") }
    }()

    /// In a test process, the store is this plist in the per-user temporary
    /// folder, one per process: a suite named by an absolute path keeps its
    /// file at that path, so nothing is written to ~/Library/Preferences.
    /// The file is deleted before the first use, since a crashed test
    /// process with the same process ID may have left one, and when the
    /// process exits; cfprefsd does not write a path suite back once its
    /// writer has gone.
    public static let testStorePath: String = {
        let path = FileManager.default.temporaryDirectory
            .appending(
                path: "org.jgkarlin.Ohia.tests.shared-defaults-\(ProcessInfo.processInfo.processIdentifier).plist",
                directoryHint: .notDirectory)
            .path
        try? FileManager.default.removeItem(atPath: path)
        atexit { try? FileManager.default.removeItem(atPath: OhiaSharedDefaults.testStorePath) }
        return path
    }()

    /// In a test process, the test store and never the live suite.
    public static var store: UserDefaults {
        if usesTestStore {
            guard let defaults = UserDefaults(suiteName: testStorePath) else {
                preconditionFailure("Unable to open the Ohia test defaults")
            }
            return defaults
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to open Ohia App Group defaults: \(suiteName)")
        }
        return defaults
    }
}
