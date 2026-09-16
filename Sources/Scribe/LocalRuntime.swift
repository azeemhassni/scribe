import Foundation

/// A model that can be downloaded and run without any prerequisites.
struct LocalModel: Identifiable, Hashable {
    let id: String
    let name: String
    let fileName: String
    let url: URL
    let downloadBytes: Int64
    let recommendedForRAM: UInt64
    let detail: String

    var localURL: URL { Paths.models.appendingPathComponent(fileName) }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }
}

/// Downloads and supervises a local `llama-server`, so Scribe works on a machine
/// with nothing else installed.
///
/// Ollama gives better notes and is preferred when present. This is the
/// fallback: the same llama.cpp engine, fetched directly.
@MainActor
final class LocalRuntime: ObservableObject {

    static let shared = LocalRuntime()

    /// Pinned rather than "latest": an unattended upgrade of the inference
    /// engine underneath a working install is not a good surprise. Bump
    /// deliberately, and check the tarball layout still matches.
    nonisolated static let build = "b10872"
    nonisolated private static let runtimeURL = URL(string:
        "https://github.com/ggml-org/llama.cpp/releases/download/\(build)/llama-\(build)-bin-macos-arm64.tar.gz")!

    /// 8848 rather than llama.cpp's default 8080, which is heavily squatted on.
    nonisolated static let port = 8848
    nonisolated static let host = URL(string: "http://127.0.0.1:\(port)")!

    nonisolated static let models: [LocalModel] = [
        LocalModel(id: "qwen2.5-3b",
                   name: "Qwen2.5 3B",
                   fileName: "qwen2.5-3b-instruct-q4_k_m.gguf",
                   url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
                   downloadBytes: 2_104_000_000,
                   recommendedForRAM: 8,
                   detail: "Fastest. Fine for short meetings with clear actions."),
        LocalModel(id: "qwen2.5-7b",
                   name: "Qwen2.5 7B",
                   fileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
                   url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
                   downloadBytes: 4_683_000_000,
                   recommendedForRAM: 16,
                   detail: "A good balance. Recommended for most machines."),
        LocalModel(id: "qwen2.5-14b",
                   name: "Qwen2.5 14B",
                   fileName: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
                   url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf")!,
                   downloadBytes: 8_988_000_000,
                   recommendedForRAM: 32,
                   detail: "Best notes from the built-in engine. Slower to start."),
    ]

    /// Picks a tier the machine can actually hold, biggest first.
    nonisolated static func recommendedModel() -> LocalModel {
        let gigabytes = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return models.last { gigabytes >= $0.recommendedForRAM } ?? models[0]
    }

    nonisolated static func model(id: String) -> LocalModel {
        models.first { $0.id == id } ?? recommendedModel()
    }

    // MARK: - Runtime files

    nonisolated private static var runtimeDirectory: URL {
        Paths.support.appendingPathComponent("runtime", isDirectory: true)
    }
    nonisolated static var serverBinary: URL {
        runtimeDirectory.appendingPathComponent("llama-server")
    }
    nonisolated static var isRuntimeInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: serverBinary.path)
    }
    /// The tarball is ~11 MB; the model beside it is gigabytes.
    nonisolated static let runtimeDownloadBytes: Int64 = 11_500_000

    func installRuntime(onProgress: @escaping @Sendable (Downloader.Progress) -> Void) async throws {
        if Self.isRuntimeInstalled { return }
        let archive = Paths.support.appendingPathComponent("llama-runtime.tar.gz")
        try await Downloader.download(from: Self.runtimeURL, to: archive, onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: archive) }

        try? FileManager.default.removeItem(at: Self.runtimeDirectory)
        try FileManager.default.createDirectory(at: Self.runtimeDirectory, withIntermediateDirectories: true)

        // The archive nests everything under llama-<build>/; flatten it so the
        // server sits next to its dylibs at a stable path.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", Self.runtimeDirectory.path, "--strip-components=1"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw ChatError.badResponse("Could not unpack the inference runtime.")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: Self.serverBinary.path)
    }

    // MARK: - Server

    private var process: Process?

    var isServerRunning: Bool { process?.isRunning ?? false }

    /// Brings the server up if it is not already answering.
    func ensureServerRunning(model: LocalModel, contextTokens: Int) async throws {
        if await isHealthy() { return }
        guard Self.isRuntimeInstalled else {
            throw ChatError.unreachable("the inference runtime is not installed")
        }
        guard model.isDownloaded else {
            throw ChatError.modelMissing(model.name)
        }

        killStaleServer()

        let process = Process()
        process.executableURL = Self.serverBinary
        process.arguments = [
            "-m", model.localURL.path,
            "--host", "127.0.0.1",
            "--port", String(Self.port),
            "-c", String(contextTokens),
            "-ngl", "99",       // everything on the GPU; these are small models
            "--no-webui",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process

        // Loading several gigabytes of weights takes a while on a cold cache.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await isHealthy() { return }
            guard process.isRunning else {
                throw ChatError.unreachable("the inference server exited while starting")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ChatError.unreachable("the inference server did not start within two minutes")
    }

    func stopServer() {
        process?.terminate()
        process = nil
    }

    func isHealthy() async -> Bool {
        var request = URLRequest(url: Self.host.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Clears a server orphaned by a crash or force-quit, which would otherwise
    /// hold the port and answer with the wrong model loaded.
    private func killStaleServer() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", ":\(Self.port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        lsof.waitUntilExit()

        for line in output.split(separator: "\n") {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
            kill(pid, SIGTERM)
        }
    }
}
