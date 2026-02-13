import Foundation

/// Manages "Launch at Login" via a LaunchAgent plist
enum LaunchAtLogin {
    static let plistName = "com.clockoo.plist"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(plistName)
    }

    /// The path to the currently running binary
    static var executablePath: String {
        ProcessInfo.processInfo.arguments[0]
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() throws {
        let launchAgentsDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": "com.clockoo",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        print("[LaunchAtLogin] Enabled: \(plistURL.path)")
    }

    static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
        print("[LaunchAtLogin] Disabled")
    }
}
