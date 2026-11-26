import Foundation

/// Recognises the processes Sparkle 2 runs to install an update, by the
/// executable paths it gives them, so the uninstaller waits for an install in
/// progress instead of removing Ohia under it.
///
/// For a sandboxed app (SUEnableInstallerLauncherService), the Installer XPC
/// service in Sparkle.framework submits two launchd jobs, `Autoupdate` and the
/// progress tool `Updater.app`, at their paths inside the same framework
/// version folder; nothing is copied elsewhere (Sparkle 2.10.1,
/// SUInstallerLauncher.m `pathForBundledTool` and its two callers). Sparkle
/// resolves symbolic links first, so the paths name `Versions/<version>`, not
/// `Versions/Current`. While installing, Autoupdate moves the old bundle into
/// a temporary folder, so the app around the framework can be at any path.
public enum SparkleInstallerProcess {
    /// The installer tools, relative to `Sparkle.framework/Versions/<version>`.
    static let toolPaths = [
        "Autoupdate",
        "Updater.app/Contents/MacOS/Updater",
        "XPCServices/Installer.xpc/Contents/MacOS/Installer",
    ]
    private static let versionsFolder = "/Contents/Frameworks/Sparkle.framework/Versions"

    /// The path of the app whose Sparkle.framework holds `executablePath`,
    /// when it is one of Sparkle's installer tools; nil for anything else.
    /// The caller decides whether that app is Ohia.
    public static func hostApp(ofExecutablePath executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        for tool in toolPaths {
            let toolSuffix = "/" + tool
            guard executablePath.hasSuffix(toolSuffix) else { continue }
            let versionFolder = executablePath.dropLast(toolSuffix.count)
            guard let slash = versionFolder.lastIndex(of: "/") else { continue }
            let version = versionFolder[versionFolder.index(after: slash)...]
            let versions = versionFolder[..<slash]
            guard !version.isEmpty, version != ".", version != "..", version != "Current",
                  versions.hasSuffix(versionsFolder)
            else { continue }
            let app = versions.dropLast(versionsFolder.count)
            guard app.hasSuffix(".app"), let nameStart = app.lastIndex(of: "/"),
                  app[app.index(after: nameStart)...].count > ".app".count
            else { continue }
            return String(app)
        }
        return nil
    }
}
