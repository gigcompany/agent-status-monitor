import Foundation

/// Postgres through Supabase's PostgREST API.
struct SupabaseBackend: StatusBackend {
    let url: String
    let key: String
    let table: String

    var describe: String { "supabase \(table)" }

    func fetchTasks(since: Date) async throws -> [AgentTask] {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        let sinceValue = isoFormatter.string(from: since)

        var components = URLComponents(string: "\(base)/rest/v1/\(table)")
        components?.queryItems = [
            URLQueryItem(name: "updated_at", value: "gt.\(sinceValue)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "updated_at.desc"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let endpoint = components?.url else {
            throw BackendError.notConfigured("Invalid Supabase URL: \(url)")
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let data = try await fetchJSON(request)

        // Columns are snake_case in Postgres; AgentTask is camelCase.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TaskList.self, from: data).tasks
    }
}
