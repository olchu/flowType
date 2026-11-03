import Foundation

/// Everything a request to the external cleanup model needs, taken from
/// the settings and the Keychain at the moment of the dictation.
nonisolated struct ExternalLLMConfiguration: Sendable, Equatable {
    var settings: ExternalLLMSettings
    var apiKey: String
    /// The dictionary's spellings, shown to the model so it keeps them.
    var vocabulary: [String]

    var provider: ExternalLLMProvider { settings.provider }
}

/// Talks to the OpenAI chat completions API, which OpenAI, Gemini, Groq,
/// OpenRouter, Ollama and LM Studio all serve, and to Anthropic's Messages
/// API. Plain URLSession: one request, one answer, nothing kept.
nonisolated enum ExternalLLMClient {
    enum Failure: LocalizedError {
        case invalidURL
        case missingModel
        case missingAPIKey
        case timedOut
        case refused
        case emptyResponse
        case http(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "The server address isn't a valid URL."
            case .missingModel: "Choose a model."
            case .missingAPIKey: "Enter the API key."
            case .timedOut: "The model didn't answer in time."
            case .refused: "The model refused to answer."
            case .emptyResponse: "The model answered with nothing."
            case let .http(status, message): message.isEmpty ? "The server answered \(status)." : "\(status): \(message)"
            }
        }
    }

    struct Message: Sendable {
        enum Role: String, Sendable { case user, assistant }
        let role: Role
        let content: String
    }

    /// A dictation waits no longer than this for its cleanup; the
    /// rule-based text is pasted instead. A server on this Mac may have to
    /// load the model first.
    static func timeout(for settings: ExternalLLMSettings) -> Duration {
        settings.isLocal ? .seconds(30) : .seconds(8)
    }

    /// The model's answer to `messages` after the `system` prompt.
    static func complete(
        system: String,
        messages: [Message],
        maxTokens: Int,
        configuration: ExternalLLMConfiguration
    ) async throws -> String {
        guard configuration.settings.host != nil else { throw Failure.invalidURL }
        guard !configuration.settings.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.missingModel }
        try validateKey(configuration)
        return try await withDeadline(timeout(for: configuration.settings)) {
            if configuration.provider.usesAnthropicAPI {
                try await anthropicCompletion(system: system, messages: messages, maxTokens: maxTokens, configuration: configuration)
            } else {
                try await chatCompletion(system: system, messages: messages, configuration: configuration)
            }
        }
    }

    /// The models the server offers, for choosing one.
    static func models(configuration: ExternalLLMConfiguration) async throws -> [String] {
        try validateKey(configuration)
        return try await withDeadline(.seconds(10)) {
            // Anthropic hands out 20 at a time unless asked for more.
            let path = configuration.provider.usesAnthropicAPI ? "models?limit=1000" : "models"
            var request = try request(path: path, configuration: configuration)
            request.httpMethod = "GET"
            let json = try await send(request)
            let models = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            // Gemini lists "models/gemini-…" but takes the bare name.
            return models.map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }.sorted()
        }
    }

    private static func validateKey(_ configuration: ExternalLLMConfiguration) throws {
        if configuration.provider.requiresAPIKey && configuration.apiKey.isEmpty {
            throw Failure.missingAPIKey
        }
    }

    private static func chatCompletion(
        system: String, messages: [Message], configuration: ExternalLLMConfiguration
    ) async throws -> String {
        // Only what every server takes: OpenAI's newer models reject
        // `max_tokens` and a non-default `temperature`, and others reject
        // OpenAI's own replacements.
        let body: [String: Any] = [
            "model": configuration.settings.model,
            "stream": false,
            "messages": [["role": "system", "content": system]]
                + messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        var request = try request(path: "chat/completions", configuration: configuration)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)

        let choice = (json["choices"] as? [[String: Any]])?.first
        if choice?["finish_reason"] as? String == "content_filter" { throw Failure.refused }
        guard let content = (choice?["message"] as? [String: Any])?["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyResponse
        }
        return content
    }

    private static func anthropicCompletion(
        system: String, messages: [Message], maxTokens: Int, configuration: ExternalLLMConfiguration
    ) async throws -> String {
        // Low effort keeps the current models from thinking long over a
        // proofreading job. Older models reject the field, so that 400 is
        // retried once without it.
        var body: [String: Any] = [
            "model": configuration.settings.model,
            // Thinking counts against the limit too.
            "max_tokens": maxTokens + 2_048,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "output_config": ["effort": "low"],
        ]

        func attempt() async throws -> [String: Any] {
            var request = try request(path: "messages", configuration: configuration)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try await send(request)
        }

        let json: [String: Any]
        do {
            json = try await attempt()
        } catch let Failure.http(status: 400, message) where message.contains("output_config") || message.contains("effort") {
            body["output_config"] = nil
            json = try await attempt()
        }

        if json["stop_reason"] as? String == "refusal" { throw Failure.refused }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyResponse }
        return text
    }

    private static func request(path: String, configuration: ExternalLLMConfiguration) throws -> URLRequest {
        var base = configuration.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(path)"), url.host() != nil else { throw Failure.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = configuration.apiKey
        if configuration.provider.usesAnthropicAPI {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(status) else {
            // OpenAI-style and Anthropic errors both carry error.message.
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["error"] as? String)
                ?? ""
            throw Failure.http(status: status, message: String(message.prefix(200)))
        }
        guard let json else { throw Failure.emptyResponse }
        return json
    }

    /// No cache, no cookies: dictations aren't kept anywhere on the way.
    private static let session = URLSession(configuration: .ephemeral)

    private static func withDeadline<T: Sendable>(
        _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Failure.timedOut }
            return result
        }
    }
}
