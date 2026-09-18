import Foundation
import SQLite3

/// Reads the SQLite file every local agent writes to. No account, no network.
///
/// Agents write in WAL mode, so reads never block their writes.
struct LocalBackend: StatusBackend {
    let path: String

    var describe: String { "local \((path as NSString).lastPathComponent)" }

    func fetchTasks(since: Date) async throws -> [AgentTask] {
        // No database yet just means no agent has reported - not an error.
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        var db: OpaquePointer?
        // Opened read-write because WAL recovery needs it; we only ever SELECT.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw BackendError.local("Cannot open \(path): \(message)")
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, agent_id, agent_label, agent_kind, host, task, status, detail,
                   question, step, total, repo, cwd, started_at, updated_at,
                   ended_at, waiting_since
            FROM agent_tasks WHERE updated_at > ? ORDER BY updated_at DESC LIMIT 200
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            // The table only appears once an agent has reported something.
            if message.contains("no such table") { return [] }
            throw BackendError.local("Query failed: \(message)")
        }
        defer { sqlite3_finalize(statement) }

        let sinceValue = isoFormatter.string(from: since)
        sqlite3_bind_text(statement, 1, (sinceValue as NSString).utf8String, -1, nil)

        func text(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, index) else { return nil }
            let value = String(cString: raw)
            return value.isEmpty ? nil : value
        }
        func number(_ index: Int32) -> Int? {
            sqlite3_column_type(statement, index) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(statement, index))
        }

        var tasks: [AgentTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0) else { continue }
            tasks.append(
                AgentTask(
                    id: id,
                    agentId: text(1) ?? "unknown",
                    agentLabel: text(2),
                    agentKind: text(3),
                    host: text(4),
                    task: text(5) ?? "Untitled task",
                    status: TaskStatus(rawValue: text(6) ?? "") ?? .working,
                    detail: text(7),
                    question: text(8),
                    step: number(9),
                    total: number(10),
                    repo: text(11),
                    cwd: text(12),
                    startedAt: AgentTask.parseDate(text(13)),
                    updatedAt: AgentTask.parseDate(text(14)),
                    endedAt: AgentTask.parseDate(text(15)),
                    waitingSince: AgentTask.parseDate(text(16))
                )
            )
        }
        return tasks
    }
}
