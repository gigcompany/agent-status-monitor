import Foundation
import CryptoKit

/// Azure Cosmos DB NoSQL API, signed with the account master key.
struct CosmosBackend: StatusBackend {
    let endpoint: String
    let key: String
    let database: String
    let container: String

    var describe: String { "cosmos \(database)/\(container)" }

    private var collectionLink: String { "dbs/\(database)/colls/\(container)" }

    private static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private func authHeader(verb: String, resourceType: String, link: String, date: String) -> String? {
        guard let keyData = Data(base64Encoded: key) else { return nil }
        let payload = "\(verb.lowercased())\n\(resourceType.lowercased())\n\(link)\n\(date.lowercased())\n\n"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: keyData))
        let token = "type=master&ver=1.0&sig=\(Data(mac).base64EncodedString())"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return token.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    func fetchTasks(since: Date) async throws -> [AgentTask] {
        // No ORDER BY: the Cosmos gateway will not serve a cross-partition sort
        // over the REST API. StatusStore sorts the result instead.
        let query: [String: Any] = [
            "query": "SELECT * FROM c WHERE c.updatedAt > @since",
            "parameters": [["name": "@since", "value": isoFormatter.string(from: since)]],
        ]

        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let link = collectionLink
        let date = Self.rfc1123.string(from: Date())
        guard let auth = authHeader(verb: "POST", resourceType: "docs", link: link, date: date),
              let url = URL(string: "\(base)/\(link)/docs")
        else { throw BackendError.notConfigured("Invalid Cosmos endpoint or key") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: query)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(date, forHTTPHeaderField: "x-ms-date")
        request.setValue("2018-12-31", forHTTPHeaderField: "x-ms-version")
        request.setValue("application/query+json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-ms-documentdb-isquery")
        request.setValue("true", forHTTPHeaderField: "x-ms-documentdb-query-enablecrosspartition")
        request.setValue("200", forHTTPHeaderField: "x-ms-max-item-count")

        let data = try await fetchJSON(request)
        return try JSONDecoder().decode(CosmosResponse.self, from: data).documents
    }
}

private struct CosmosResponse: Decodable {
    let documents: [AgentTask]

    private enum CodingKeys: String, CodingKey { case documents = "Documents" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decode(TaskList.self, forKey: .documents).tasks
    }
}
