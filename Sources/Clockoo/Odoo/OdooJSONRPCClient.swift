import Foundation

/// Lightweight JSON-RPC client for Odoo's /jsonrpc endpoint
/// No dependencies — uses URLSession + Codable
final class OdooJSONRPCClient: Sendable {
    let url: String
    let database: String
    let username: String
    let apiKey: String

    private let session: URLSession
    private let endpoint: URL

    /// Cached user ID after authentication
    private let _uid = ManagedAtomic<Int?>(nil)

    init(url: String, database: String, username: String, apiKey: String) {
        self.url = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.database = database
        self.username = username
        self.apiKey = apiKey
        self.endpoint = URL(string: "\(self.url)/jsonrpc")!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - JSON-RPC Transport

    /// Send a JSON-RPC call and decode the result
    func call<T: Decodable>(service: String, method: String, args: [Any]) async throws -> T {
        let requestId = Int.random(in: 1...999999)

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "call",
            "params": [
                "service": service,
                "method": method,
                "args": args,
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OdooError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw OdooError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse the JSON-RPC response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let error = json["error"] as? [String: Any] {
            let message = (error["data"] as? [String: Any])?["message"] as? String
                ?? error["message"] as? String
                ?? "Unknown Odoo error"
            throw OdooError.odooError(message: message)
        }

        // The result is in json["result"]
        guard let result = json["result"] else {
            throw OdooError.noResult
        }

        // Re-serialize the result and decode to the expected type
        let resultData = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: resultData)
    }

    // MARK: - Authentication

    /// Authenticate and return the user ID
    func authenticate() async throws -> Int {
        if let uid = _uid.value {
            return uid
        }

        let uid: Int = try await call(
            service: "common",
            method: "authenticate",
            args: [database, username, apiKey, [:] as [String: Any]]
        )

        guard uid > 0 else {
            throw OdooError.authenticationFailed
        }

        _uid.value = uid
        return uid
    }

    // MARK: - Model Operations

    /// Call execute_kw on an Odoo model
    func executeKw(
        model: String,
        method: String,
        args: [Any],
        kwargs: [String: Any] = [:]
    ) async throws -> Any {
        let uid = try await authenticate()

        let callArgs: [Any] = [
            database, uid, apiKey, model, method, args,
            kwargs.isEmpty ? [:] as [String: Any] : kwargs,
        ]

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...999999),
            "method": "call",
            "params": [
                "service": "object",
                "method": "execute_kw",
                "args": callArgs,
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OdooError.invalidResponse
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let error = json["error"] as? [String: Any] {
            let message = (error["data"] as? [String: Any])?["message"] as? String
                ?? error["message"] as? String
                ?? "Unknown Odoo error"
            throw OdooError.odooError(message: message)
        }

        guard let result = json["result"] else {
            throw OdooError.noResult
        }

        return result
    }

    /// Search and read records
    func searchRead(
        model: String,
        domain: [[Any]],
        fields: [String],
        limit: Int? = nil
    ) async throws -> [[String: Any]] {
        var kwargs: [String: Any] = ["fields": fields]
        if let limit { kwargs["limit"] = limit }

        let result = try await executeKw(
            model: model,
            method: "search_read",
            args: [domain],
            kwargs: kwargs
        )

        guard let records = result as? [[String: Any]] else {
            throw OdooError.unexpectedResultType
        }
        return records
    }

    /// Call a method on specific record IDs
    func callMethod(
        model: String,
        method: String,
        ids: [Int]
    ) async throws {
        _ = try await executeKw(model: model, method: method, args: [ids])
    }
}

// MARK: - Thread-safe mutable value

/// Simple thread-safe wrapper (no external dependencies)
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
    case httpError(statusCode: Int)
    case authenticationFailed
    case odooError(message: String)
    case noResult
    case unexpectedResultType

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Odoo"
        case .httpError(let code): return "HTTP error \(code)"
        case .authenticationFailed: return "Authentication failed — check credentials"
        case .odooError(let msg): return "Odoo: \(msg)"
        case .noResult: return "No result in Odoo response"
        case .unexpectedResultType: return "Unexpected result type from Odoo"
        }
    }
}
