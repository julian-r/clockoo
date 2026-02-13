import Foundation

/// Odoo JSON-2 API client (Odoo 19+)
/// Uses POST /json/2/<model>/<method> with bearer token auth
final class OdooJSON2Client: OdooClient, Sendable {
    let url: String
    let database: String
    let username: String
    let apiKey: String

    private let session: URLSession
    private let baseURL: URL
    private let _uid = ManagedAtomic<Int?>(nil)

    init(url: String, database: String, username: String, apiKey: String) {
        let (sanitized, base) = sanitizeOdooURL(url)
        self.url = sanitized
        self.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = base
        self.session = makeOdooSession()
    }

    // MARK: - OdooClient

    func authenticate() async throws -> Int {
        if let uid = _uid.value { return uid }

        let records = try await searchRead(
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

    func searchRead(
        model: String, domain: [[Any]], fields: [String], limit: Int? = nil
    ) async throws -> [[String: Any]] {
        var body: [String: Any] = ["domain": domain, "fields": fields]
        if let limit { body["limit"] = limit }

        let result = try await request(model: model, method: "search_read", body: body)
        guard let records = result as? [[String: Any]] else {
            throw OdooError.unexpectedResultType
        }
        return records
    }

    func callMethodReturning(
        model: String, method: String, ids: [Int]
    ) async throws -> Any {
        try await request(model: model, method: method, body: ["ids": ids])
    }

    func callMethodWithKwargs(
        model: String, method: String, args: [Any], kwargs: [String: Any] = [:]
    ) async throws -> Any {
        var body: [String: Any] = [:]
        if let ids = args.first as? [Int] {
            body["ids"] = ids
        }
        for (k, v) in kwargs { body[k] = v }
        return try await request(model: model, method: method, body: body)
    }

    func nameSearch(
        model: String, name: String, domain: [[Any]] = [], limit: Int = 7
    ) async throws -> [(id: Int, name: String)] {
        let result = try await request(
            model: model, method: "name_search",
            body: ["name": name, "domain": domain, "limit": limit]
        )
        return parseNameSearchResult(result)
    }

    func create(model: String, values: [String: Any]) async throws -> Int {
        let result = try await request(model: model, method: "create", body: ["values": values])
        if let ids = result as? [Int], let id = ids.first { return id }
        if let id = result as? Int { return id }
        throw OdooError.unexpectedResultType
    }



    // MARK: - Transport

    private func request(model: String, method: String, body: [String: Any]) async throws -> Any {
        let endpoint = baseURL.appendingPathComponent("json/2/\(model)/\(method)")

        guard JSONSerialization.isValidJSONObject(body) else {
            throw OdooError.invalidRequest(detail: "Cannot serialize request body to JSON")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !database.isEmpty {
            req.setValue(database, forHTTPHeaderField: "X-Odoo-Database")
        }
        req.setValue("Clockoo", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OdooError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorObj["message"] as? String {
                throw OdooError.odooError(message: "HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OdooError.httpError(statusCode: httpResponse.statusCode)
        }

        // JSON-2 responses can be bare values: null, false, true, numbers, strings,
        // or JSON arrays/objects. Handle all cases gracefully.
        if data.isEmpty { return NSNull() }

        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw == "null" || raw == "false" { return NSNull() }
        if raw == "true" { return true as Any }

        // Try parsing as JSON object/array first
        if let parsed = try? JSONSerialization.jsonObject(with: data) {
            return parsed
        }

        // Bare number (e.g. action_timer_stop returns elapsed hours like "0.25")
        if let number = Double(raw) {
            return number
        }

        // Bare string
        return raw
    }
}
