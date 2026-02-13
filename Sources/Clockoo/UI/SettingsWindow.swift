import SwiftUI

/// Settings window for managing Odoo accounts
struct SettingsView: View {
    @ObservedObject var accountManager: AccountManager
    @State private var accounts: [EditableAccount] = []
    @State private var selectedAccountId: String?
    /// Separate editing copy — prevents sidebar re-renders from stealing focus
    @State private var editingAccount: EditableAccount?
    @State private var showDeleteConfirm = false
    @State private var testResult: TestResult?

    @State private var blinkWhenIdle: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 450)
        .onAppear { loadAccounts() }
        .onChange(of: selectedAccountId) { _, newId in
            syncEditingAccount(to: newId)
        }
        .alert("Delete Account?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelectedAccount() }
        } message: {
            Text("This will remove the account and its API key from Keychain.")
        }
    }

    /// Copy selected account into editingAccount (separate state, no sidebar coupling)
    private func syncEditingAccount(to id: String?) {
        if let id, let account = accounts.first(where: { $0.id == id }) {
            editingAccount = account
        } else {
            editingAccount = nil
        }
        testResult = nil
    }

    // MARK: - Sidebar

    private static let generalId = "__general__"

    private var sidebar: some View {
        List(selection: $selectedAccountId) {
            Section("General") {
                Label("Preferences", systemImage: "gearshape")
                    .tag(Self.generalId)
            }

            Section("Accounts") {
                ForEach(accounts) { account in
                    accountRow(account)
                        .tag(account.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button(action: addAccount) {
                    Image(systemName: "plus")
                }
                .help("Add account")

                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "minus")
                }
                .disabled(selectedAccountId == nil)
                .help("Remove account")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
    }

    private func accountRow(_ account: EditableAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.hasKeychainKey ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(account.hasKeychainKey ? .green : .secondary)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.label.isEmpty ? "New Account" : account.label)
                    .font(.body)
                    .fontWeight(.medium)
                Text(account.url.isEmpty ? "Not configured" : prettifyURL(account.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if selectedAccountId == Self.generalId {
            generalSettingsView
        } else if editingAccount != nil {
            AccountEditorView(
                account: Binding(
                    get: { editingAccount! },
                    set: { editingAccount = $0 }
                ),
                testResult: $testResult,
                onTest: { if let acc = editingAccount { testConnection(account: acc) } },
                onSave: saveAll
            )
        } else {
            ContentUnavailableView(
                "No Account Selected",
                systemImage: "person.crop.circle",
                description: Text("Select an account from the sidebar, or add a new one.")
            )
        }
    }

    private var generalSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Menu Bar")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $blinkWhenIdle) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Blink when idle")
                                Text("Blink the menu bar icon when no timer is running")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onChange(of: blinkWhenIdle) { _, _ in
                            persistConfig()
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
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
                hasKeychainKey: KeychainHelper.getAPIKey(for: config.id) != nil,
                apiVersion: config.apiVersion
            )
        }
        blinkWhenIdle = accountManager.blinkWhenIdle
        selectedAccountId = Self.generalId
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
            hasKeychainKey: false,
            apiVersion: .json2
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
        editingAccount = nil
        selectedAccountId = accounts.first?.id
        syncEditingAccount(to: selectedAccountId)

        // Persist without going through saveAll (no editingAccount to write back)
        persistConfig()
    }

    /// Write current accounts array to disk and reload the manager
    private func persistConfig() {
        let configs = accounts.map { acc in
            AccountConfig(
                id: acc.id,
                label: acc.label,
                url: acc.url,
                database: acc.database,
                username: acc.username,
                apiVersion: acc.apiVersion
            )
        }

        let clockooConfig = ClockooConfig(accounts: configs, blinkWhenIdle: blinkWhenIdle)
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

        // Refresh keychain indicators in sidebar
        for i in accounts.indices {
            accounts[i].hasKeychainKey = KeychainHelper.getAPIKey(for: accounts[i].id) != nil
        }
    }

    /// Write editingAccount back into the accounts array, sanitize, and persist
    private func saveAll() {
        // Write the editing copy back into the array
        if var edited = editingAccount,
           let index = accounts.firstIndex(where: { $0.id == selectedAccountId })
        {
            let oldId = edited.id

            // Sanitize
            edited.url = edited.url
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            edited.database = edited.database
                .trimmingCharacters(in: .whitespacesAndNewlines)
            edited.username = edited.username
                .trimmingCharacters(in: .whitespacesAndNewlines)
            edited.id = edited.id
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            edited.label = edited.label
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // If ID changed, migrate the Keychain entry
            if oldId != edited.id {
                if let existingKey = KeychainHelper.getAPIKey(for: oldId) {
                    try? KeychainHelper.setAPIKey(existingKey, for: edited.id)
                    KeychainHelper.deleteAPIKey(for: oldId)
                }
            }

            // Save API key to Keychain if provided
            let key = edited.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try? KeychainHelper.setAPIKey(key, for: edited.id)
                edited.apiKey = ""  // Clear from memory after storing
                edited.hasKeychainKey = true
            }

            accounts[index] = edited
            selectedAccountId = edited.id
            editingAccount = edited
        }

        persistConfig()
    }

    private func testConnection(account: EditableAccount) {
        // Auto-save before testing so the key is in Keychain
        saveAll()

        testResult = .testing

        let resolvedId = editingAccount?.id ?? account.id
        let apiKey: String
        let enteredKey = (editingAccount?.apiKey ?? account.apiKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !enteredKey.isEmpty {
            apiKey = enteredKey
        } else {
            apiKey = KeychainHelper.getAPIKey(for: resolvedId) ?? ""
        }

        guard !apiKey.isEmpty else {
            testResult = .failure("No API key — enter one above or save first")
            return
        }

        let client = OdooJSONRPCClient(
            url: account.url,
            database: account.database,
            username: account.username,
            apiKey: apiKey,
            apiVersion: account.apiVersion
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

    private func prettifyURL(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "")
           .replacingOccurrences(of: "http://", with: "")
           .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - Account Editor

struct AccountEditorView: View {
    @Binding var account: EditableAccount
    @Binding var testResult: TestResult?
    let onTest: () -> Void
    let onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Account section
                sectionCard("Account") {
                    LabeledField("ID") {
                        TextField("e.g. work, freelance", text: $account.id)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Label") {
                        TextField("Display name", text: $account.label)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // Connection section
                sectionCard("Odoo Connection") {
                    LabeledField("URL") {
                        TextField("https://mycompany.odoo.com", text: $account.url)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Database") {
                        TextField("mycompany", text: $account.database)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Username") {
                        TextField("user@example.com", text: $account.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField("API Version") {
                        Picker("", selection: $account.apiVersion) {
                            Text("JSON-2 (Odoo 19+, recommended)").tag(OdooAPIVersion.json2)
                            Text("Legacy JSON-RPC (Odoo 14–18)").tag(OdooAPIVersion.legacy)
                        }
                        .pickerStyle(.radioGroup)
                    }
                }

                // API Key section
                sectionCard("Authentication") {
                    LabeledField("API Key") {
                        SecureField(
                            account.hasKeychainKey
                                ? "Stored in Keychain ✓ (leave empty to keep)"
                                : "Enter your Odoo API key",
                            text: $account.apiKey
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    if account.hasKeychainKey && account.apiKey.isEmpty {
                        Label(
                            "API key is securely stored in macOS Keychain",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                // Test + Save
                HStack(spacing: 16) {
                    Button(action: onTest) {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .controlSize(.large)

                    testResultView

                    Spacer()

                    Button(action: onSave) {
                        Label("Save", systemImage: "checkmark.circle.fill")
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        if let result = testResult {
            switch result {
            case .testing:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Testing...")
                        .foregroundStyle(.secondary)
                }
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func sectionCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Labeled Field

struct LabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content
        }
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
    var apiVersion: OdooAPIVersion
}

enum TestResult {
    case testing
    case success(String)
    case failure(String)
}
