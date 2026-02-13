import Foundation
#if canImport(Network)
import Network
#endif

/// Tiny local HTTP server for Stream Deck and other integrations
/// Uses NWListener from Network framework — no dependencies
@MainActor
final class LocalAPIServer {
    private var listener: Any?  // NWListener, but kept as Any for build compat
    private nonisolated(unsafe) var accountManager: AccountManager
    let port: UInt16

    init(accountManager: AccountManager, port: UInt16 = 19847) {
        self.accountManager = accountManager
        self.port = port
    }

    func start() {
        #if canImport(Network)
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let nwListener = try NWListener(using: .tcp, on: nwPort)

            let port = self.port
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[LocalAPI] Listening on port \(port)")
                case .failed(let error):
                    print("[LocalAPI] Failed: \(error)")
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in
                    self.handleConnection(connection)
                }
            }

            nwListener.start(queue: .main)
            self.listener = nwListener
        } catch {
            print("[LocalAPI] Failed to start: \(error)")
        }
        #endif
    }

    func stop() {
        #if canImport(Network)
        (listener as? NWListener)?.cancel()
        listener = nil
        #endif
    }

    #if canImport(Network)
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, error in
            guard let self, let data else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                let response = self.handleRequest(request)
                let responseData = response.data(using: .utf8)!
                connection.send(
                    content: responseData,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            }
        }
    }

    private func handleRequest(_ raw: String) -> String {
        let lines = raw.split(separator: "\r\n")
        guard let firstLine = lines.first else {
            return httpResponse(status: 400, body: #"{"error":"Bad request"}"#)
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return httpResponse(status: 400, body: #"{"error":"Bad request"}"#)
        }

        let method = String(parts[0])
        let path = String(parts[1])

        switch (method, path) {
        case ("GET", "/api/timers"):
            return handleGetTimers()
        case ("GET", "/api/accounts"):
            return handleGetAccounts()
        case let ("POST", p) where p.hasPrefix("/api/timers/") && p.hasSuffix("/toggle"):
            let timerId = extractTimerId(from: p, action: "toggle")
            return handleTimerAction(timerId: timerId, action: "toggle")
        case let ("POST", p) where p.hasPrefix("/api/timers/") && p.hasSuffix("/start"):
            let timerId = extractTimerId(from: p, action: "start")
            return handleTimerAction(timerId: timerId, action: "start")
        case let ("POST", p) where p.hasPrefix("/api/timers/") && p.hasSuffix("/stop"):
            let timerId = extractTimerId(from: p, action: "stop")
            return handleTimerAction(timerId: timerId, action: "stop")
        case let ("POST", p) where p.hasPrefix("/api/timers/") && p.hasSuffix("/pause"):
            let timerId = extractTimerId(from: p, action: "pause")
            return handleTimerAction(timerId: timerId, action: "pause")
        default:
            return httpResponse(status: 404, body: #"{"error":"Not found"}"#)
        }
    }

    private func handleGetTimers() -> String {
        let timers = accountManager.allTimesheets.map { ts in
            [
                "id": "\(ts.accountId):\(ts.id)",
                "name": ts.name,
                "displayLabel": ts.displayLabel,
                "projectName": ts.projectName ?? "",
                "accountId": ts.accountId,
                "state": "\(ts.state)",
                "elapsed": ts.elapsedFormatted,
                "elapsedSeconds": "\(Int(ts.elapsed))",
            ] as [String: String]
        }

        guard let json = try? JSONSerialization.data(withJSONObject: timers),
              let body = String(data: json, encoding: .utf8)
        else {
            return httpResponse(status: 500, body: #"{"error":"Serialization failed"}"#)
        }
        return httpResponse(status: 200, body: body)
    }

    private func handleGetAccounts() -> String {
        let accounts = accountManager.accounts.map { acc in
            ["id": acc.id, "label": acc.label, "url": acc.url]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: accounts),
              let body = String(data: json, encoding: .utf8)
        else {
            return httpResponse(status: 500, body: #"{"error":"Serialization failed"}"#)
        }
        return httpResponse(status: 200, body: body)
    }

    private func handleTimerAction(timerId: String?, action: String) -> String {
        guard let timerId,
              let timesheet = findTimesheet(compositeId: timerId)
        else {
            return httpResponse(status: 404, body: #"{"error":"Timer not found"}"#)
        }

        switch action {
        case "toggle": accountManager.toggleTimer(timesheet: timesheet)
        case "start": accountManager.startTimer(timesheet: timesheet)
        case "stop": accountManager.stopTimer(timesheet: timesheet)
        case "delete": accountManager.deleteTimesheet(timesheet: timesheet)
        default: break
        }

        return httpResponse(status: 200, body: #"{"ok":true}"#)
    }

    private func findTimesheet(compositeId: String) -> Timesheet? {
        // ID format: "accountId:timesheetId"
        let parts = compositeId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let tsId = Int(parts[1])
        else { return nil }
        let accountId = String(parts[0])
        return accountManager.timesheetsByAccount[accountId]?.first { $0.id == tsId }
    }

    private func extractTimerId(from path: String, action: String) -> String? {
        // /api/timers/{id}/{action}
        let stripped = path
            .replacingOccurrences(of: "/api/timers/", with: "")
            .replacingOccurrences(of: "/\(action)", with: "")
        return stripped.isEmpty ? nil : stripped
    }

    private func httpResponse(status: Int, body: String) -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        return """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """
    }
    #endif
}
