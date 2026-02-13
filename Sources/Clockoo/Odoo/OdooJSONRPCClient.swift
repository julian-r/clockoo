import Foundation

/// API version to use for communicating with Odoo
enum OdooAPIVersion: String, Codable {
    /// Legacy JSON-RPC at /jsonrpc (Odoo 14-19, deprecated in Odoo 20)
    case legacy = "legacy"
    /// New JSON-2 API at /json/2/ (Odoo 19+, recommended)
    case json2 = "json2"
}

/// Lightweight JSON-RPC client for Odoo
/// Supports both legacy /jsonrpc and new /json/2/ endpoints
/// No dependencies — uses URLSession + Codable
final class OdooJSONRPCClient: Sendable {
    let url: String
    let database: String
    let username: String
    let apiKey: String
    let apiVersion: OdooAPIVersion

    private let session: URLSession
    private let baseURL: URL

    /// Cached user ID after authentication (legacy API only)
    private let _uid = ManagedAtomic<Int?>(nil)

    init(
        url: String,
        database: String,
        username: String,
        apiKey: String,
        apiVersion: OdooAPIVersion = .json2
    ) {
        // Sanitize URL: trim whitespace, trailing slashes, ensure https://
        var sanitized = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !sanitized.hasPrefix("http://") && !sanitized.hasPrefix("https://") {
            sanitized = "https://\(sanitized)"
        }

        self.url = sanitized
        self.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiVersion = apiVersion

        self.baseURL = URL(string: self.url) ?? URL(string: "https://invalid.local")!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Authenticate and return the user ID
    func authenticate() async throws -> Int {
        switch apiVersion {
        case .json2:
            return try await authenticateJSON2()
        case .legacy:
            return try await authenticateLegacy()
        }
    }

    /// Search and read records
    func searchRead(
        model: String,
        domain: [[Any]],
        fields: [String],
        limit: Int? = nil
    ) async throws -> [[String: Any]] {
        switch apiVersion {
        case .json2:
            return try await searchReadJSON2(model: model, domain: domain, fields: fields, limit: limit)
        case .legacy:
            return try await searchReadLegacy(model: model, domain: domain, fields: fields, limit: limit)
        }
    }

    /// Call a method on specific record IDs
    func callMethod(
        model: String,
        method: String,
        ids: [Int]
    ) async throws {
        switch apiVersion {
        case .json2:
            try await callMethodJSON2(model: model, method: method, ids: ids)
        case .legacy:
            try await callMethodLegacy(model: model, method: method, ids: ids)
        }
    }

    /// name_search: Odoo's built-in autocomplete search
    /// Returns [(id, display_name)] pairs
    func nameSearch(
        model: String,
        name: String,
        domain: [[Any]] = [],
        limit: Int = 7
    ) async throws -> [(id: Int, name: String)] {
        switch apiVersion {
        case .json2:
            return try await nameSearchJSON2(model: model, name: name, domain: domain, limit: limit)
        case .legacy:
            return try await nameSearchLegacy(model: model, name: name, domain: domain, limit: limit)
        }
    }

    /// Create a record and return its ID
    func create(
        model: String,
        values: [String: Any]
    ) async throws -> Int {
        switch apiVersion {
        case .json2:
            return try await createJSON2(model: model, values: values)
        case .legacy:
            return try await createLegacy(model: model, values: values)
        }
    }

    // MARK: - JSON-2 API (Odoo 19+)
    // POST /json/2/<model>/<method>
    // Authorization: bearer <api-key>

    private func authenticateJSON2() async throws -> Int {
        // JSON-2 uses bearer auth, no separate authenticate call needed.
        // We call res.users/search_read to get the current user's ID.
        let records = try await searchReadJSON2(
            model: "res.users",
            domain: [["login", "=", username]],
            fields: ["id"],
            limit: 1
        )
        guard let first = records.first, let uid = first["id"] as? Int else {
            throw OdooError.authenticationFailed
        }
        _uid.value = uid
        return uid
    }

    private func searchReadJSON2(
        model: String,
        domain: [[Any]],
        fields: [String],
        limit: Int? = nil
    ) async throws -> [[String: Any]] {
        var body: [String: Any] = [
            "domain": domain,
            "fields": fields,
        ]
        if let limit { body["limit"] = limit }

        let result = try await requestJSON2(model: model, method: "search_read", body: body)

        guard let records = result as? [[String: Any]] else {
            throw OdooError.unexpectedResultType
        }
        return records
    }

    private func callMethodJSON2(model: String, method: String, ids: [Int]) async throws {
        let body: [String: Any] = [
            "ids": ids,
        ]
        _ = try await requestJSON2(model: model, method: method, body: body)
    }

    private func nameSearchJSON2(
        model: String, name: String, domain: [[Any]], limit: Int
    ) async throws -> [(id: Int, name: String)] {
        let body: [String: Any] = [
            "name": name,
            "domain": domain,
            "limit": limit,
        ]
        let result = try await requestJSON2(model: model, method: "name_search", body: body)
        return parseNameSearchResult(result)
    }

    private func createJSON2(model: String, values: [String: Any]) async throws -> Int {
        let body: [String: Any] = [
            "values": values,
        ]
        let result = try await requestJSON2(model: model, method: "create", body: body)
        // create returns [id] in JSON-2
        if let ids = result as? [Int], let id = ids.first { return id }
        if let id = result as? Int { return id }
        throw OdooError.unexpectedResultType
    }

    private func requestJSON2(model: String, method: String, body: [String: Any]) async throws -> Any {
        let endpoint = baseURL.appendingPathComponent("json/2/\(model)/\(method)")

        guard JSONSerialization.isValidJSONObject(body) else {
            throw OdooError.invalidRequest(detail: "Cannot serialize request body to JSON")
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !database.isEmpty {
            request.setValue(database, forHTTPHeaderField: "X-Odoo-Database")
        }
        request.setValue("Clockoo", forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OdooError.invalidResponse
        }

        // JSON-2 API: success = 200 with result, error = 4xx/5xx with error object
        guard httpResponse.statusCode == 200 else {
            // Try to parse error body
            if let errorObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorObj["message"] as? String {
                throw OdooError.odooError(message: "HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OdooError.httpError(statusCode: httpResponse.statusCode)
        }

        // Handle bare null/false/true responses (e.g. action_timer_start returns null)
        if data.isEmpty { return NSNull() }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw == "null" || raw == "false" { return NSNull() }
        if raw == "true" { return true as Any }

        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Legacy JSON-RPC API (Odoo 14-19)
    // POST /jsonrpc

    private func authenticateLegacy() async throws -> Int {
        if let uid = _uid.value {
            return uid
        }

        let uid: Int = try await callLegacy(
            service: "common",
            method: "authenticate",
            args: [database, username, apiKey, [String: String]()]
        )

        guard uid > 0 else {
            throw OdooError.authenticationFailed
        }

        _uid.value = uid
        return uid
    }

    private func searchReadLegacy(
        model: String,
        domain: [[Any]],
        fields: [String],
        limit: Int? = nil
    ) async throws -> [[String: Any]] {
        var kwargs: [String: Any] = ["fields": fields]
        if let limit { kwargs["limit"] = limit }

        let result = try await executeKwLegacy(
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

    private func callMethodLegacy(model: String, method: String, ids: [Int]) async throws {
        _ = try await executeKwLegacy(model: model, method: method, args: [ids])
    }

    private func nameSearchLegacy(
        model: String, name: String, domain: [[Any]], limit: Int
    ) async throws -> [(id: Int, name: String)] {
        let result = try await executeKwLegacy(
            model: model, method: "name_search", args: [],
            kwargs: ["name": name, "args": domain, "limit": limit]
        )
        return parseNameSearchResult(result)
    }

    private func createLegacy(model: String, values: [String: Any]) async throws -> Int {
        let result = try await executeKwLegacy(
            model: model, method: "create", args: [values]
        )
        if let id = result as? Int { return id }
        if let ids = result as? [Int], let id = ids.first { return id }
        throw OdooError.unexpectedResultType
    }

    /// Send a legacy JSON-RPC call and decode the result
    private func callLegacy<T: Decodable>(service: String, method: String, args: [Any]) async throws -> T {
        let endpoint = baseURL.appendingPathComponent("jsonrpc")

        let params: [String: Any] = [
            "service": service,
            "method": method,
            "args": args,
        ]

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...999999),
            "method": "call",
            "params": params,
        ]

        guard JSONSerialization.isValidJSONObject(body) else {
            throw OdooError.invalidRequest(detail: "Cannot serialize request body to JSON")
        }

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

        let resultData = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: resultData)
    }

    /// Call execute_kw via legacy JSON-RPC
    private func executeKwLegacy(
        model: String,
        method: String,
        args: [Any],
        kwargs: [String: Any] = [:]
    ) async throws -> Any {
        let uid = try await authenticateLegacy()

        let callArgs: [Any] = [
            database, uid, apiKey, model, method, args,
            kwargs.isEmpty ? [String: String]() : kwargs,
        ]

        let endpoint = baseURL.appendingPathComponent("jsonrpc")

        let params: [String: Any] = [
            "service": "object",
            "method": "execute_kw",
            "args": callArgs,
        ]

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...999999),
            "method": "call",
            "params": params,
        ]

        guard JSONSerialization.isValidJSONObject(body) else {
            throw OdooError.invalidRequest(detail: "Cannot serialize execute_kw request to JSON")
        }

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

    // MARK: - Shared Helpers

    private func parseNameSearchResult(_ result: Any) -> [(id: Int, name: String)] {
        guard let pairs = result as? [[Any]] else { return [] }
        return pairs.compactMap { pair in
            guard pair.count >= 2,
                  let id = pair[0] as? Int,
                  let name = pair[1] as? String
            else { return nil }
            return (id: id, name: name)
        }
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
