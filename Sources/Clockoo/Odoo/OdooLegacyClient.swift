import Foundation

/// Odoo Legacy JSON-RPC client (Odoo 14-18)
/// Uses POST /jsonrpc with service/method/args envelope
final class OdooLegacyClient: OdooClient, Sendable {
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

        let uid: Int = try await callService(
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

    func searchRead(
        model: String, domain: [[Any]], fields: [String], limit: Int? = nil
    ) async throws -> [[String: Any]] {
        var kwargs: [String: Any] = ["fields": fields]
        if let limit { kwargs["limit"] = limit }

        let result = try await executeKw(model: model, method: "search_read", args: [domain], kwargs: kwargs)
        guard let records = result as? [[String: Any]] else {
            throw OdooError.unexpectedResultType
        }
        return records
    }

    func callMethodReturning(
        model: String, method: String, ids: [Int]
    ) async throws -> Any {
        try await executeKw(model: model, method: method, args: [ids])
    }

    func callMethodWithKwargs(
        model: String, method: String, args: [Any], kwargs: [String: Any] = [:]
    ) async throws -> Any {
        try await executeKw(model: model, method: method, args: args, kwargs: kwargs)
    }

    func nameSearch(
        model: String, name: String, domain: [[Any]] = [], limit: Int = 7
    ) async throws -> [(id: Int, name: String)] {
        let result = try await executeKw(
            model: model, method: "name_search", args: [],
            kwargs: ["name": name, "args": domain, "limit": limit]
        )
        return parseNameSearchResult(result)
    }

    func create(model: String, values: [String: Any]) async throws -> Int {
        let result = try await executeKw(model: model, method: "create", args: [values])
        if let id = result as? Int { return id }
        if let ids = result as? [Int], let id = ids.first { return id }
        throw OdooError.unexpectedResultType
    }



    // MARK: - Transport

    /// Call a JSON-RPC service method (e.g. common/authenticate) and decode the result
    private func callService<T: Decodable>(service: String, method: String, args: [Any]) async throws -> T {
        let json = try await jsonrpc(params: [
            "service": service,
            "method": method,
            "args": args,
        ])

        guard let result = json["result"] else {
            throw OdooError.noResult
        }

        // Handle primitive types that JSONSerialization can't serialize as top-level objects
        let resultData: Data
        if JSONSerialization.isValidJSONObject(result) {
            resultData = try JSONSerialization.data(withJSONObject: result)
        } else if let num = result as? NSNumber, T.self == Int.self {
            resultData = Data("\(num.intValue)".utf8)
        } else if let str = result as? String {
            resultData = Data("\"\(str)\"".utf8)
        } else if let bool = result as? Bool {
            resultData = Data(bool ? "true".utf8 : "false".utf8)
        } else {
            resultData = try JSONSerialization.data(withJSONObject: [result])
        }
        return try JSONDecoder().decode(T.self, from: resultData)
    }

    /// Call execute_kw and return the raw result
    private func executeKw(
        model: String,
        method: String,
        args: [Any],
        kwargs: [String: Any] = [:]
    ) async throws -> Any {
        let uid = try await authenticate()

        let json = try await jsonrpc(params: [
            "service": "object",
            "method": "execute_kw",
            "args": [
                database, uid, apiKey, model, method, args,
                kwargs.isEmpty ? [String: String]() : kwargs,
            ],
        ])

        // Some Odoo methods return no "result" key (e.g. action_timer_start returns None).
        // Treat missing result as null — the action succeeded if no error was raised.
        guard let result = json["result"] else {
            return NSNull()
        }

        return result
    }

    /// Send a JSON-RPC request and return the parsed response dict.
    /// Throws on HTTP errors and Odoo-level errors.
    private func jsonrpc(params: [String: Any]) async throws -> [String: Any] {
        let endpoint = baseURL.appendingPathComponent("jsonrpc")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...999_999),
            "method": "call",
            "params": params,
        ]

        guard JSONSerialization.isValidJSONObject(body) else {
            throw OdooError.invalidRequest(detail: "Cannot serialize request body to JSON")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)

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

        return json
    }
}
