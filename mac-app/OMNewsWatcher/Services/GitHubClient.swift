import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum GitHubAPIError: LocalizedError {
    case invalidURL
    case missingToken
    case invalidResponse
    case http(Int, String)
    case invalidBase64

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige GitHub-URL."
        case .missingToken:
            return "Bitte zuerst den GitHub-Zugriff in den Einstellungen hinterlegen."
        case .invalidResponse:
            return "GitHub hat eine unerwartete Antwort geliefert."
        case .http(let code, let message):
            return "GitHub-Fehler \(code): \(message)"
        case .invalidBase64:
            return "GitHub-Datei konnte nicht dekodiert werden."
        }
    }
}

struct RepositorySettings {
    var owner: String
    var repo: String
    var branch: String
    var workflow: String
    var sourcesPath: String
}

struct GitHubFile {
    let sha: String
    let data: Data
}

private struct GitHubContentResponse: Decodable {
    let sha: String
    let content: String
    let encoding: String
}

private struct GitHubUpdateResponse: Decodable {
    struct UpdatedContent: Decodable {
        let sha: String
    }

    let content: UpdatedContent?
}

private struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct DispatchResponse: Decodable {
    let workflowRunID: Int64?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case workflowRunID = "workflow_run_id"
        case htmlURL = "html_url"
    }
}

struct GitHubClient {
    static let apiVersion = "2026-03-10"

    private let settings: RepositorySettings
    private let token: String

    init(settings: RepositorySettings, token: String) {
        self.settings = settings
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchSources() async throws -> GitHubFile {
        try await fetchFile(path: settings.sourcesPath)
    }

    func saveSources(data: Data, sha: String) async throws -> String {
        try await saveFile(
            path: settings.sourcesPath,
            data: data,
            sha: sha,
            message: "Update sources via OM News Watcher Mac"
        )
    }

    func fetchFile(path: String) async throws -> GitHubFile {
        let encodedPath = path
            .split(separator: "/")
            .map(String.init)
            .map {
                $0.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? $0
            }
            .joined(separator: "/")

        var components = URLComponents(
            string:
                "https://api.github.com/repos/\(settings.owner)/\(settings.repo)/contents/\(encodedPath)"
        )

        components?.queryItems = [
            URLQueryItem(
                name: "ref",
                value: settings.branch
            )
        ]

        guard let url = components?.url else {
            throw GitHubAPIError.invalidURL
        }

        var request = makeRequest(
            url: url,
            method: "GET"
        )

        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) =
            try await URLSession.shared.data(
                for: request
            )

        try validate(
            response: response,
            data: data
        )

        let payload =
            try JSONDecoder().decode(
                GitHubContentResponse.self,
                from: data
            )

        guard payload.encoding.lowercased() == "base64" else {
            throw GitHubAPIError.invalidResponse
        }

        let cleaned =
            payload.content
                .replacingOccurrences(
                    of: "\n",
                    with: ""
                )

        guard let decoded =
            Data(
                base64Encoded: cleaned
            )
        else {
            throw GitHubAPIError.invalidBase64
        }

        return GitHubFile(
            sha: payload.sha,
            data: decoded
        )
    }

    func fetchFileIfExists(path: String) async throws -> GitHubFile? {
        do {
            return try await fetchFile(path: path)
        } catch GitHubAPIError.http(let code, _) where code == 404 {
            return nil
        }
    }

    func saveFile(
        path: String,
        data: Data,
        sha: String?,
        message: String
    ) async throws -> String {
        guard !token.isEmpty else {
            throw GitHubAPIError.missingToken
        }

        let encodedPath = path
            .split(separator: "/")
            .map(String.init)
            .map {
                $0.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? $0
            }
            .joined(separator: "/")

        guard let url = URL(
            string:
                "https://api.github.com/repos/\(settings.owner)/\(settings.repo)/contents/\(encodedPath)"
        ) else {
            throw GitHubAPIError.invalidURL
        }

        struct Body: Encodable {
            let message: String
            let content: String
            let sha: String?
            let branch: String
        }

        let body = Body(
            message: message,
            content: data.base64EncodedString(),
            sha: sha,
            branch: settings.branch
        )

        var request = makeRequest(
            url: url,
            method: "PUT"
        )

        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody =
            try JSONEncoder().encode(body)

        let (responseData, response) =
            try await URLSession.shared.data(
                for: request
            )

        try validate(
            response: response,
            data: responseData
        )

        let payload =
            try JSONDecoder().decode(
                GitHubUpdateResponse.self,
                from: responseData
            )

        return payload.content?.sha ?? sha ?? ""
    }


    func dispatchWorkflow() async throws -> WorkflowRun? {
        try await dispatchWorkflow(
            workflow: settings.workflow,
            inputs: [:]
        )

        return nil
    }

    func dispatchWorkflow(
        workflow: String,
        inputs: [String: String]
    ) async throws {
        guard !token.isEmpty else {
            throw GitHubAPIError.missingToken
        }

        guard let workflowName =
            workflow.addingPercentEncoding(
                withAllowedCharacters:
                    .urlPathAllowed
            ),
            let url = URL(
                string:
                    "https://api.github.com/repos/\(settings.owner)/\(settings.repo)/actions/workflows/\(workflowName)/dispatches"
            )
        else {
            throw GitHubAPIError.invalidURL
        }

        struct Body: Encodable {
            let ref: String
            let inputs: [String: String]?
        }

        var request =
            makeRequest(
                url: url,
                method: "POST"
            )

        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody =
            try JSONEncoder().encode(
                Body(
                    ref: settings.branch,
                    inputs:
                        inputs.isEmpty
                        ? nil
                        : inputs
                )
            )

        let (data, response) =
            try await URLSession.shared.data(
                for: request
            )

        try validate(
            response: response,
            data: data,
            acceptedStatusCodes: [
                200,
                204
            ]
        )
    }

    func latestWorkflowRun() async throws -> WorkflowRun? {
        guard let workflowName = settings.workflow.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw GitHubAPIError.invalidURL
        }

        var components = URLComponents(
            string: "https://api.github.com/repos/\(settings.owner)/\(settings.repo)/actions/workflows/\(workflowName)/runs"
        )
        components?.queryItems = [
            URLQueryItem(name: "branch", value: settings.branch),
            URLQueryItem(name: "per_page", value: "1")
        ]

        guard let url = components?.url else { throw GitHubAPIError.invalidURL }

        var request = makeRequest(url: url, method: "GET")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let payload = try JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        return payload.workflowRuns.first
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("OM-News-Watcher-Mac/1.6", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")

        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func validate(
        response: URLResponse,
        data: Data,
        acceptedStatusCodes: Set<Int> = [200, 201]
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }

        guard acceptedStatusCodes.contains(http.statusCode) else {
            let message: String

            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let apiMessage = object["message"] as? String {
                message = apiMessage
            } else {
                message = String(data: data, encoding: .utf8) ?? "Unbekannter Fehler"
            }

            throw GitHubAPIError.http(http.statusCode, message)
        }
    }
}
