import AppKit
import Foundation

/// Detection and model management for a local Ollama install.
///
/// Everything goes over Ollama's HTTP API rather than its CLI: the binary is not
/// always on PATH for a GUI app, and the API reports pull progress, which
/// shelling out does not.
enum OllamaService {

    static func isRunning(host: String) async -> Bool {
        guard let url = URL(string: host)?.appendingPathComponent("api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    static let appBundleID = "com.electron.ollama"

    /// Opens the Ollama app in the background and waits for its server.
    ///
    /// Only for a server on this machine: a remote host is somebody else's to
    /// start.
    static func launch(host: String) async throws {
        let local = URL(string: host)?.host.map { ["127.0.0.1", "localhost", "::1"].contains($0) } ?? false
        guard local else {
            throw ChatError.ollamaNotRunning("Could not reach Ollama at \(host).")
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else {
            throw ChatError.ollamaNotRunning("Ollama isn't running, and the Ollama app isn't installed. Install it, or switch to the built-in engine in Setup.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if await isRunning(host: host) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ChatError.ollamaNotRunning("Ollama was opened but did not start answering within 30 seconds.")
    }

    static func installedModels(host: String) async -> [String] {
        guard let url = URL(string: host)?.appendingPathComponent("api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    /// Streams a pull, reporting progress. Ollama replies with one JSON object
    /// per line, so the response is read as it arrives rather than buffered.
    static func pull(model: String,
                     host: String,
                     onProgress: @escaping @Sendable (String, Double?) -> Void) async throws {
        guard let url = URL(string: host)?.appendingPathComponent("api/pull") else {
            throw ChatError.unreachable(host)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChatError.badResponse("Ollama replied \(http.statusCode) — is `\(model)` a real model name?")
        }

        for try await line in stream.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = json["error"] as? String {
                throw ChatError.badResponse(error)
            }
            let status = json["status"] as? String ?? "Pulling…"
            if let completed = json["completed"] as? Int64, let total = json["total"] as? Int64, total > 0 {
                onProgress("\(Downloader.humanBytes(completed)) of \(Downloader.humanBytes(total))",
                           Double(completed) / Double(total))
            } else {
                onProgress(status, nil)
            }
        }
    }
}
