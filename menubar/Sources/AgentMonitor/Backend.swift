import Foundation

/// Anything the menu bar app can read task state from.
protocol StatusBackend: Sendable {
    func fetchTasks(since: Date) async throws -> [AgentTask]
    var describe: String { get }
}

enum BackendError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case transport(String)
    case local(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return what
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(140))"
        case .transport(let message):  return message
        case .local(let message):      return message
        }
    }
}

/// Reads the same `~/.agent-status/config.env` the CLI uses, so the app and the
/// agents can never disagree about where status lives.
struct AppConfig {
    var backend: String = "supabase"
    var localPath: String = "~/.agent-status/status.db"
    var supabaseURL: String = ""
    var supabaseKey: String = ""
    var supabaseTable: String = "agent_tasks"
    var cosmosEndpoint: String = ""
    var cosmosKey: String = ""
    var cosmosDatabase: String = "agentmonitor"
    var cosmosContainer: String = "tasks"
    var pollSeconds: Int = 5
    var lookbackHours: Int = 12
    var notifyWaiting: Bool = true
    var notifyDone: Bool = true

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-status/config.env")
    }

    static func load() -> AppConfig? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let split = line.firstIndex(of: "=") else { continue }

            let key = String(line[line.startIndex..<split]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }

        // A real environment variable wins, matching the CLI's precedence.
        func read(_ name: String) -> String? {
            ProcessInfo.processInfo.environment[name] ?? values[name]
        }

        var config = AppConfig()
        config.backend = (read("AGENT_STATUS_BACKEND") ?? "supabase").lowercased()
        config.localPath = read("AGENT_STATUS_LOCAL_PATH") ?? config.localPath
        config.supabaseURL = read("AGENT_STATUS_SUPABASE_URL") ?? ""
        config.supabaseKey = read("AGENT_STATUS_SUPABASE_KEY") ?? ""
        config.supabaseTable = read("AGENT_STATUS_SUPABASE_TABLE") ?? config.supabaseTable
        config.cosmosEndpoint = read("AGENT_STATUS_COSMOS_ENDPOINT") ?? ""
        config.cosmosKey = read("AGENT_STATUS_COSMOS_KEY") ?? ""
        config.cosmosDatabase = read("AGENT_STATUS_COSMOS_DATABASE") ?? config.cosmosDatabase
        config.cosmosContainer = read("AGENT_STATUS_COSMOS_CONTAINER") ?? config.cosmosContainer
        config.pollSeconds = read("AGENT_STATUS_POLL_SECONDS").flatMap(Int.init) ?? config.pollSeconds
        config.lookbackHours = read("AGENT_STATUS_LOOKBACK_HOURS").flatMap(Int.init) ?? config.lookbackHours
        config.notifyWaiting = boolean(read("AGENT_STATUS_NOTIFY_WAITING"), default: true)
        config.notifyDone = boolean(read("AGENT_STATUS_NOTIFY_DONE"), default: true)
        return config
    }

    private static func boolean(_ value: String?, default fallback: Bool) -> Bool {
        guard let value = value?.lowercased() else { return fallback }
        return ["1", "true", "yes", "on"].contains(value)
    }

    var expandedLocalPath: String {
        localPath.hasPrefix("~")
            ? NSString(string: localPath).expandingTildeInPath
            : localPath
    }

    func makeBackend() throws -> StatusBackend {
        switch backend {
        case "local":
            return LocalBackend(path: expandedLocalPath)
        case "supabase":
            guard !supabaseURL.isEmpty, !supabaseKey.isEmpty else {
                throw BackendError.notConfigured(
                    "Supabase not configured - set AGENT_STATUS_SUPABASE_URL and _KEY"
                )
            }
            return SupabaseBackend(url: supabaseURL, key: supabaseKey, table: supabaseTable)
        case "cosmos":
            guard !cosmosEndpoint.isEmpty, !cosmosKey.isEmpty else {
                throw BackendError.notConfigured(
                    "Cosmos not configured - set AGENT_STATUS_COSMOS_ENDPOINT and _KEY"
                )
            }
            return CosmosBackend(
                endpoint: cosmosEndpoint, key: cosmosKey,
                database: cosmosDatabase, container: cosmosContainer
            )
        default:
            throw BackendError.notConfigured("Unknown backend '\(backend)' - use local, supabase or cosmos")
        }
    }
}

/// Shared JSON HTTP helper for the cloud backends.
func fetchJSON(_ request: URLRequest) async throws -> Data {
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    } catch let error as BackendError {
        throw error
    } catch let error as URLError {
        throw BackendError.transport(error.localizedDescription)
    }
}

let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()
