import Foundation

/// Protocol for Odoo API clients.
/// Two implementations: OdooJSON2Client (Odoo 19+) and OdooLegacyClient (Odoo 14-18).
protocol OdooClient: Sendable {
    /// The base URL of the Odoo instance
    var url: String { get }

    /// Authenticate and return the user ID
    func authenticate() async throws -> Int

    /// Search and read records from a model
    func searchRead(
        model: String,
        domain: [[Any]],
        fields: [String],
        limit: Int?
    ) async throws -> [[String: Any]]

    /// Call a method on specific record IDs (fire-and-forget)
    func callMethod(model: String, method: String, ids: [Int]) async throws

    /// Call a method on specific record IDs and return the raw result
    func callMethodReturning(model: String, method: String, ids: [Int]) async throws -> Any

    /// Call a method with custom args and kwargs
    func callMethodWithKwargs(
        model: String,
        method: String,
        args: [Any],
        kwargs: [String: Any]
    ) async throws -> Any

    /// Odoo's name_search autocomplete — returns (id, display_name) pairs
    func nameSearch(
        model: String,
        name: String,
        domain: [[Any]],
        limit: Int
    ) async throws -> [(id: Int, name: String)]

    /// Create a record and return its ID
    func create(model: String, values: [String: Any]) async throws -> Int
}

// MARK: - Default implementations

extension OdooClient {
    func searchRead(
        model: String, domain: [[Any]], fields: [String]
    ) async throws -> [[String: Any]] {
        try await searchRead(model: model, domain: domain, fields: fields, limit: nil)
    }

    func callMethod(model: String, method: String, ids: [Int]) async throws {
        _ = try await callMethodReturning(model: model, method: method, ids: ids)
    }

    func callMethodWithKwargs(
        model: String, method: String, args: [Any]
    ) async throws -> Any {
        try await callMethodWithKwargs(model: model, method: method, args: args, kwargs: [:])
    }

    func nameSearch(
        model: String, name: String, domain: [[Any]] = [], limit: Int = 7
    ) async throws -> [(id: Int, name: String)] {
        try await nameSearch(model: model, name: name, domain: domain, limit: limit)
    }
}

// MARK: - Factory

/// Auto-detect the Odoo version and create the appropriate client + backend.
/// Probes the JSON-2 endpoint first (Odoo 19+); falls back to legacy JSON-RPC.
struct OdooConnection {
    let client: OdooClient
    let backend: OdooTimerBackend
}

func makeOdooConnection(
    url: String,
    database: String,
    username: String,
    apiKey: String
) async -> OdooConnection {
    let json2 = OdooJSON2Client(url: url, database: database, username: username, apiKey: apiKey)
    do {
        _ = try await json2.authenticate()
        print("[Odoo] \(url) → Odoo 19+ (JSON-2 API)")
        return OdooConnection(client: json2, backend: Odoo19TimerBackend())
    } catch {
        print("[Odoo] \(url) → Odoo 14-18 (legacy JSON-RPC)")
        let legacy = OdooLegacyClient(url: url, database: database, username: username, apiKey: apiKey)
        return OdooConnection(client: legacy, backend: OdooLegacyTimerBackend())
    }
}

// MARK: - Shared Helpers

/// Parse Odoo's name_search result: [[id, "display_name"], ...]
func parseNameSearchResult(_ result: Any) -> [(id: Int, name: String)] {
    guard let pairs = result as? [[Any]] else { return [] }
    return pairs.compactMap { pair in
        guard pair.count >= 2,
              let id = pair[0] as? Int,
              let name = pair[1] as? String
        else { return nil }
        return (id: id, name: name)
    }
}

// MARK: - Thread-safe mutable value

final class ManagedAtomic<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - Errors

enum OdooError: Error, LocalizedError {
    case invalidResponse
    case invalidRequest(detail: String)
    case invalidURL(url: String)
    case httpError(statusCode: Int)
    case authenticationFailed
    case odooError(message: String)
    case noResult
    case unexpectedResultType

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Odoo"
        case .invalidRequest(let detail): return "Invalid request: \(detail)"
        case .invalidURL(let url): return "Invalid Odoo URL: \(url)"
        case .httpError(let code): return "HTTP error \(code)"
        case .authenticationFailed: return "Authentication failed — check credentials"
        case .odooError(let msg): return "Odoo: \(msg)"
        case .noResult: return "No result in Odoo response"
        case .unexpectedResultType: return "Unexpected result type from Odoo"
        }
    }
}

/// Sanitize an Odoo URL: trim whitespace/slashes, ensure scheme
func sanitizeOdooURL(_ raw: String) -> (url: String, baseURL: URL) {
    var sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !sanitized.hasPrefix("http://") && !sanitized.hasPrefix("https://") {
        sanitized = "https://\(sanitized)"
    }
    let base = URL(string: sanitized) ?? URL(string: "https://invalid.local")!
    return (sanitized, base)
}

/// Create a URLSession with standard Odoo timeout
func makeOdooSession() -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    return URLSession(configuration: config)
}
