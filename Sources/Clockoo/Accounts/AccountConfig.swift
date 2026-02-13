import Foundation

/// A single Odoo account configuration (no secrets — API key lives in Keychain)
struct AccountConfig: Codable, Identifiable {
    let id: String
    let label: String
    let url: String
    let database: String
    let username: String
    /// API version: "json2" (Odoo 19+, default) or "legacy" (Odoo 14-18)
    var apiVersion: OdooAPIVersion

    init(id: String, label: String, url: String, database: String, username: String, apiVersion: OdooAPIVersion = .json2) {
        self.id = id
        self.label = label
        self.url = url
        self.database = database
        self.username = username
        self.apiVersion = apiVersion
    }

    // Decode with fallback for configs without apiVersion field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decode(String.self, forKey: .url)
        database = try container.decode(String.self, forKey: .database)
        username = try container.decode(String.self, forKey: .username)
        apiVersion = try container.decodeIfPresent(OdooAPIVersion.self, forKey: .apiVersion) ?? .json2
    }
}

/// Root config file structure
struct ClockooConfig: Codable {
    let accounts: [AccountConfig]
}

/// Loads accounts from ~/.config/clockoo/accounts.json
enum ConfigLoader {
    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clockoo")

    static let configFile = configDir.appendingPathComponent("accounts.json")

    static func load() throws -> [AccountConfig] {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return []
        }
        let data = try Data(contentsOf: configFile)
        let config = try JSONDecoder().decode(ClockooConfig.self, from: data)
        return config.accounts
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
                username: "user@example.com",
                apiVersion: .json2
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sample)
        try data.write(to: configFile)
    }
}
