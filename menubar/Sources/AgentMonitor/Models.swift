import Foundation

enum TaskStatus: String, Codable, CaseIterable {
    case working, waiting, done, failed

    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .waiting: return "questionmark.circle.fill"
        case .done:    return "checkmark.circle.fill"
        case .failed:  return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done:    return "Done"
        case .failed:  return "Failed"
        }
    }

    /// Lower sorts first in the dropdown.
    var priority: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .failed:  return 2
        case .done:    return 3
        }
    }
}

struct AgentTask: Codable, Identifiable, Equatable {
    let id: String
    var agentId: String
    var agentLabel: String?
    var agentKind: String?
    var host: String?
    var task: String
    var status: TaskStatus
    var detail: String?
    var question: String?
    var step: Int?
    var total: Int?
    var repo: String?
    var cwd: String?
    var startedAt: Date?
    var updatedAt: Date?
    var endedAt: Date?
    var waitingSince: Date?

    var displayAgent: String { agentLabel ?? agentId }

    var note: String? {
        guard let text = question ?? detail,
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return text
    }

    var progressText: String? {
        guard let step, let total, total > 0 else { return nil }
        return "\(step)/\(total)"
    }

    /// A task still "working" long after its last update has probably died.
    /// An agent that crashes cannot report its own death.
    var isStale: Bool {
        guard status == .working, let updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt) > 30 * 60
    }

    var isActive: Bool { status == .working || status == .waiting }

    /// Age of whichever timestamp the row actually displays - waiting time
    /// while blocked, otherwise time since the last update.
    private var displayReference: Date? { waitingSince ?? updatedAt }

    /// Manually formatted instead of `Text(date, format: .relative(...))`:
    /// that SwiftUI formatter has been observed rendering large offsets (tens
    /// of minutes) as "N sec ago" on this platform, which directly
    /// contradicts `isStale` computed from the exact same timestamp. A plain
    /// arithmetic string cannot have that failure mode.
    var ageDescription: String? {
        guard let reference = displayReference else { return nil }
        let seconds = Date().timeIntervalSince(reference)
        guard seconds >= 0 else { return "just now" }

        switch seconds {
        case ..<5:      return "just now"
        case ..<60:     return "\(Int(seconds))s ago"
        case ..<3600:   return "\(Int(seconds / 60))m ago"
        case ..<86400:  return "\(Int(seconds / 3600))h ago"
        default:        return "\(Int(seconds / 86400))d ago"
        }
    }

    init(
        id: String, agentId: String, agentLabel: String?, agentKind: String?, host: String?,
        task: String, status: TaskStatus, detail: String?, question: String?,
        step: Int?, total: Int?, repo: String?, cwd: String?,
        startedAt: Date?, updatedAt: Date?, endedAt: Date?, waitingSince: Date?
    ) {
        self.id = id; self.agentId = agentId; self.agentLabel = agentLabel
        self.agentKind = agentKind; self.host = host; self.task = task
        self.status = status; self.detail = detail; self.question = question
        self.step = step; self.total = total; self.repo = repo; self.cwd = cwd
        self.startedAt = startedAt; self.updatedAt = updatedAt
        self.endedAt = endedAt; self.waitingSince = waitingSince
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentId, agentLabel, agentKind, host, task, status, detail, question
        case step, total, repo, cwd, startedAt, updatedAt, endedAt, waitingSince
    }

    /// Tolerant on purpose: a malformed field from one backend should not throw
    /// away an otherwise usable task.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentId = (try? c.decode(String.self, forKey: .agentId)) ?? "unknown"
        agentLabel = try? c.decodeIfPresent(String.self, forKey: .agentLabel) ?? nil
        agentKind = try? c.decodeIfPresent(String.self, forKey: .agentKind) ?? nil
        host = try? c.decodeIfPresent(String.self, forKey: .host) ?? nil
        task = (try? c.decode(String.self, forKey: .task)) ?? "Untitled task"
        status = (try? c.decode(TaskStatus.self, forKey: .status)) ?? .working
        detail = try? c.decodeIfPresent(String.self, forKey: .detail) ?? nil
        question = try? c.decodeIfPresent(String.self, forKey: .question) ?? nil
        step = try? c.decodeIfPresent(Int.self, forKey: .step) ?? nil
        total = try? c.decodeIfPresent(Int.self, forKey: .total) ?? nil
        repo = try? c.decodeIfPresent(String.self, forKey: .repo) ?? nil
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd) ?? nil
        startedAt = AgentTask.parseDate(try? c.decodeIfPresent(String.self, forKey: .startedAt) ?? nil)
        updatedAt = AgentTask.parseDate(try? c.decodeIfPresent(String.self, forKey: .updatedAt) ?? nil)
        endedAt = AgentTask.parseDate(try? c.decodeIfPresent(String.self, forKey: .endedAt) ?? nil)
        waitingSince = AgentTask.parseDate(try? c.decodeIfPresent(String.self, forKey: .waitingSince) ?? nil)
    }

    /// Handles the three shapes the backends produce: Cosmos and SQLite write
    /// `...Z`, while Postgres returns an offset and up to 6 fractional digits.
    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }

        // Postgres microseconds (6 digits) exceed what ISO8601DateFormatter
        // accepts, so drop the fractional part and retry.
        if let dot = value.firstIndex(of: "."),
           let tail = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            var trimmed = value
            trimmed.removeSubrange(dot..<tail)
            if let date = plain.date(from: trimmed) { return date }
        }

        // Postgres can also omit the timezone entirely; assume UTC.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(identifier: "UTC")
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return naive.date(from: String(value.prefix(19)))
    }
}

/// Decodes an array of tasks, skipping any row that cannot be parsed rather
/// than failing the whole refresh.
struct TaskList: Decodable {
    let tasks: [AgentTask]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var collected: [AgentTask] = []
        while !container.isAtEnd {
            if let task = try? container.decode(AgentTask.self) {
                collected.append(task)
            } else {
                _ = try? container.decode(Discard.self)
            }
        }
        tasks = collected
    }

    private struct Discard: Decodable {
        init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer() }
    }
}
