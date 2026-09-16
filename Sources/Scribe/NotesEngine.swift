import Foundation

/// Which local model runs the summarisation.
enum NotesEngineKind: String, CaseIterable, Identifiable {
    /// Ollama, if the user already has it. Better models, bigger download.
    case ollama
    /// A bundled llama.cpp server. No prerequisites, downloaded on first run.
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .local: return "Built-in"
        }
    }
}

/// Anything that can turn a prompt into notes. Both implementations talk to
/// 127.0.0.1 and nothing else.
protocol ChatClient {
    var label: String { get }
    /// The model's name alone, as stored on a meeting.
    var modelName: String { get }
    /// How much the model can be given at once; the summariser splits long
    /// meetings against this.
    var contextWindow: Int { get }
    func chat(system: String, user: String) async throws -> String
}

enum ChatError: LocalizedError {
    case unreachable(String)
    case ollamaNotRunning(String)
    case emptyNotes
    case modelMissing(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host):
            return "Could not reach the notes model at \(host)."
        case .ollamaNotRunning(let detail):
            return detail
        case .emptyNotes:
            return "The notes model replied, but with nothing usable."
        case .modelMissing(let model):
            return "The model `\(model)` is not available. Pull it with `ollama pull \(model)`."
        case .badResponse(let detail):
            return "Unexpected response from the notes model: \(detail)"
        }
    }
}

/// Ollama's native endpoint. Preferred over its OpenAI-compatible one because
/// only this route accepts `num_ctx` — and Ollama's 4096-token default would
/// silently truncate anything longer than a short meeting.
struct OllamaClient: ChatClient {
    let host: URL
    let model: String
    let contextTokens: Int

    var label: String { "\(model) (Ollama)" }
    var modelName: String { model }
    var contextWindow: Int { contextTokens }

    func chat(system: String, user: String) async throws -> String {
        var request = URLRequest(url: host.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["num_ctx": contextTokens, "temperature": 0.2],
        ])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChatError.unreachable(host.absoluteString)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 404 { throw ChatError.modelMissing(model) }
            throw ChatError.badResponse("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ChatError.badResponse(String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return content
    }
}

/// The OpenAI-compatible `/v1/chat/completions` route, which `llama-server`
/// serves. Context size is fixed when that server starts, so there is nothing
/// to negotiate per request.
struct OpenAICompatibleClient: ChatClient {
    let host: URL
    let model: String
    let name: String
    let modelName: String
    let contextWindow: Int

    var label: String { name }

    func chat(system: String, user: String) async throws -> String {
        var request = URLRequest(url: host.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChatError.unreachable(host.absoluteString)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChatError.badResponse("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ChatError.badResponse(String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return content
    }
}


/// Builds the client the user has chosen, starting the built-in server if that
/// is what they picked.
enum NotesEngineFactory {

    @MainActor
    static func makeClient(prefs: Prefs) async throws -> ChatClient {
        switch NotesEngineKind(rawValue: prefs.notesEngine) ?? .ollama {
        case .ollama:
            guard let host = URL(string: prefs.ollamaHost) else {
                throw ChatError.unreachable(prefs.ollamaHost)
            }
            // The most common failure by far is simply that Ollama is not
            // open. Start it rather than making the user do it and retry.
            if !(await OllamaService.isRunning(host: prefs.ollamaHost)) {
                try await OllamaService.launch(host: prefs.ollamaHost)
            }
            return OllamaClient(host: host,
                                model: prefs.ollamaModel,
                                contextTokens: prefs.contextTokens)

        case .local:
            let model = LocalRuntime.model(id: prefs.localModelID)
            try await LocalRuntime.shared.ensureServerRunning(model: model,
                                                              contextTokens: prefs.contextTokens)
            return OpenAICompatibleClient(host: LocalRuntime.host,
                                          model: model.id,
                                          name: "\(model.name) (built-in)",
                                          modelName: model.name,
                                          contextWindow: prefs.contextTokens)
        }
    }
}
