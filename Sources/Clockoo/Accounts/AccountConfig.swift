import Foundation

/// A single Odoo account configuration (no secrets — API key lives in Keychain)
struct AccountConfig: Codable, Identifiable {
    let id: String
    let label: String
    let url: String
    let database: String
    let username: String
}

/// Root config file structure
struct ClockooConfig: Codable {
    let accounts: [AccountConfig]
    /// Blink menu bar icon when no timer is running
    var blinkWhenIdle: Bool

    init(accounts: [AccountConfig], blinkWhenIdle: Bool = false) {
        self.accounts = accounts
        self.blinkWhenIdle = blinkWhenIdle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decode([AccountConfig].self, forKey: .accounts)
        blinkWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .blinkWhenIdle) ?? false
    }
}

/// Loads accounts from ~/.config/clockoo/accounts.json
enum ConfigLoader {
    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clockoo")

    static let configFile = configDir.appendingPathComponent("accounts.json")

    static func load() throws -> [AccountConfig] {
        try loadConfig().accounts
    }

    static func loadConfig() throws -> ClockooConfig {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return ClockooConfig(accounts: [])
        }
        let data = try Data(contentsOf: configFile)
        return try JSONDecoder().decode(ClockooConfig.self, from: data)
    }

    /// Create config directory and a sample config if none exists
    static func ensureConfigDir() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
    }

    /// Write a sample config file for first-time setup
    static func writeSampleConfig() throws {
        ensureConfigDir()
        guard !FileManager.default.fileExists(atPath: configFile.path) else { return }
        let sample = ClockooConfig(accounts: [
            AccountConfig(
                id: "mycompany",
                label: "My Company",
                url: "https://mycompany.odoo.com",
                database: "mycompany",
                username: "user@example.com"
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sample)
        try data.write(to: configFile)
    }
}
