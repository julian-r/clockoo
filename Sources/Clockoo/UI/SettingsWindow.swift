import SwiftUI

/// Settings window for managing Odoo accounts
struct SettingsView: View {
    @ObservedObject var accountManager: AccountManager
    @State private var accounts: [EditableAccount] = []
    @State private var selectedAccountId: String?
    @State private var showDeleteConfirm = false
    @State private var testResult: TestResult?

    var body: some View {
        HSplitView {
            // Account list (left)
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedAccountId) {
                    ForEach(accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.label.isEmpty ? "New Account" : account.label)
                                    .fontWeight(.medium)
                                Text(account.url.isEmpty ? "Not configured" : account.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if account.hasKeychainKey {
                                Image(systemName: "key.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .help("API key stored in Keychain")
                            }
                        }
                        .tag(account.id)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 12) {
                    Button(action: addAccount) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Add account")

                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedAccountId == nil)
                    .help("Remove account")
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 250)

            // Account editor (right)
            if let selectedId = selectedAccountId,
               let index = accounts.firstIndex(where: { $0.id == selectedId })
            {
                AccountEditorView(
                    account: $accounts[index],
                    testResult: $testResult,
                    onTest: { testConnection(account: accounts[index]) },
                    onSave: saveAll
                )
                .frame(minWidth: 350)
            } else {
                VStack {
                    Image(systemName: "sidebar.left")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select an account")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { loadAccounts() }
        .alert("Delete Account?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelectedAccount() }
        } message: {
            Text("This will remove the account and its API key from Keychain.")
        }
    }

    // MARK: - Actions

    private func loadAccounts() {
        accounts = accountManager.accounts.map { config in
            EditableAccount(
                id: config.id,
                label: config.label,
                url: config.url,
                database: config.database,
                username: config.username,
                apiKey: "",
                hasKeychainKey: KeychainHelper.getAPIKey(for: config.id) != nil
            )
        }
        selectedAccountId = accounts.first?.id
    }

    private func addAccount() {
        let newId = "account-\(Int.random(in: 1000...9999))"
        let account = EditableAccount(
            id: newId,
            label: "",
            url: "https://",
            database: "",
            username: "",
            apiKey: "",
            hasKeychainKey: false
        )
        accounts.append(account)
        selectedAccountId = newId
    }

    private func deleteSelectedAccount() {
        guard let selectedId = selectedAccountId,
              let index = accounts.firstIndex(where: { $0.id == selectedId })
        else { return }

        KeychainHelper.deleteAPIKey(for: selectedId)
        accounts.remove(at: index)
        selectedAccountId = accounts.first?.id
        saveAll()
    }

    private func saveAll() {
        // Save API keys to Keychain
        for account in accounts {
            if !account.apiKey.isEmpty {
                try? KeychainHelper.setAPIKey(account.apiKey, for: account.id)
            }
        }

        // Save config (without secrets)
        let configs = accounts.map { acc in
            AccountConfig(
                id: acc.id,
                label: acc.label,
                url: acc.url,
                database: acc.database,
                username: acc.username
            )
        }

        let clockooConfig = ClockooConfig(accounts: configs)
        do {
            ConfigLoader.ensureConfigDir()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(clockooConfig)
            try data.write(to: ConfigLoader.configFile)
        } catch {
            print("[Settings] Failed to save config: \(error)")
        }

        // Reload accounts in the manager
        accountManager.stopPolling()
        accountManager.loadAccounts()
        accountManager.startPolling()

        // Refresh keychain indicators
        for i in accounts.indices {
            accounts[i].hasKeychainKey = KeychainHelper.getAPIKey(for: accounts[i].id) != nil
        }
    }

    private func testConnection(account: EditableAccount) {
        testResult = .testing

        let apiKey = account.apiKey.isEmpty
            ? (KeychainHelper.getAPIKey(for: account.id) ?? "")
            : account.apiKey

        guard !apiKey.isEmpty else {
            testResult = .failure("No API key — enter one above")
            return
        }

        let client = OdooJSONRPCClient(
            url: account.url,
            database: account.database,
            username: account.username,
            apiKey: apiKey
        )

        Task {
            do {
                let uid = try await client.authenticate()
                await MainActor.run {
                    testResult = .success("Connected! User ID: \(uid)")
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Account Editor

struct AccountEditorView: View {
    @Binding var account: EditableAccount
    @Binding var testResult: TestResult?
    let onTest: () -> Void
    let onSave: () -> Void

    var body: some View {
        Form {
            Section("Account") {
                TextField("ID", text: $account.id)
                    .help("Unique identifier (e.g. 'work', 'freelance')")
                TextField("Label", text: $account.label)
                    .help("Display name shown in the menu bar")
            }

            Section("Odoo Connection") {
                TextField("URL", text: $account.url)
                    .help("e.g. https://mycompany.odoo.com")
                TextField("Database", text: $account.database)
                TextField("Username", text: $account.username)
                    .help("Your Odoo login email")
            }

            Section("API Key") {
                SecureField(
                    account.hasKeychainKey ? "API Key (stored in Keychain ✓)" : "API Key",
                    text: $account.apiKey
                )
                .help("Stored securely in macOS Keychain")

                if account.hasKeychainKey && account.apiKey.isEmpty {
                    Text("Key already in Keychain. Leave empty to keep it, or enter a new one to replace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("Test Connection", action: onTest)

                    if let result = testResult {
                        switch result {
                        case .testing:
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Testing...")
                                .foregroundStyle(.secondary)
                        case .success(let msg):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(msg)
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(msg)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save", action: onSave)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Supporting Types

struct EditableAccount: Identifiable {
    var id: String
    var label: String
    var url: String
    var database: String
    var username: String
    var apiKey: String
    var hasKeychainKey: Bool
}

enum TestResult {
    case testing
    case success(String)
    case failure(String)
}
