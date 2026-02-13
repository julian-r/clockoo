import Foundation

/// Timer state derived from Odoo's timer_start field
enum TimerState {
    case running
    case stopped

    var icon: String {
        switch self {
        case .running: return "▶"
        case .stopped: return "■"
        }
    }
}

/// Source of the timer (project task, helpdesk ticket, or standalone)
enum TimerSource {
    case task(id: Int, name: String)
    case ticket(id: Int, name: String)
    case standalone

    var icon: String {
        switch self {
        case .task: return "🔧"
        case .ticket: return "🎫"
        case .standalone: return "⏱"
        }
    }

    var label: String {
        switch self {
        case .task(_, let name): return name
        case .ticket(_, let name): return name
        case .standalone: return "Timesheet"
        }
    }
}

/// A timesheet entry from Odoo's account.analytic.line model
struct Timesheet: Identifiable {
    let id: Int
    let accountId: String
    let name: String
    let projectName: String?
    let source: TimerSource
    let unitAmount: Double
    let timerStart: Date?
    let date: String

    var state: TimerState {
        guard timerStart != nil else { return .stopped }
        return .running
    }

    /// Calculate elapsed time including live running time
    var elapsed: TimeInterval {
        let baseSeconds = unitAmount * 3600
        guard let start = timerStart else { return baseSeconds }
        // Timer is running — elapsed = base + (now - start)
        return baseSeconds + Date().timeIntervalSince(start)
    }

    /// Format elapsed time as H:MM
    var elapsedFormatted: String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }

    /// The display label combining source icon and name
    var displayLabel: String {
        let srcLabel: String
        switch source {
        case .task(_, let name): srcLabel = name
        case .ticket(_, let name): srcLabel = name
        case .standalone: srcLabel = name.isEmpty ? "Timesheet" : name
        }
        return "\(source.icon) \(srcLabel)"
    }

    /// Whether this timesheet has a task or ticket to open
    var hasWebLink: Bool {
        switch source {
        case .task, .ticket: return true
        case .standalone: return false
        }
    }

    /// URL to open the source record in Odoo web
    func webURL(baseURL: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model: String
        let recordId: Int
        switch source {
        case .task(let id, _):
            model = "project.task"
            recordId = id
        case .ticket(let id, _):
            model = "helpdesk.ticket"
            recordId = id
        case .standalone:
            model = "account.analytic.line"
            recordId = id
        }
        return URL(string: "\(base)/web#id=\(recordId)&model=\(model)&view_type=form")
    }
}
