import Foundation

/// Resumable HTTP download with progress.
///
/// Models are gigabytes; a dropped connection forty minutes in must not mean
/// starting over. Bytes land in a `.part` file and a resumed download asks for
/// the remainder with a Range header.
enum Downloader {

    struct Progress {
        let completed: Int64
        let total: Int64
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    enum DownloadError: LocalizedError {
        case badStatus(Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "The server replied \(code)."
            case .cancelled: return "Download cancelled."
            }
        }
    }

    static func download(from url: URL,
                         to destination: URL,
                         onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }

        let partial = URL(fileURLWithPath: destination.path + ".part")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        var alreadyHave: Int64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
           let size = attributes[.size] as? Int64 {
            alreadyHave = size
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if alreadyHave > 0 {
            request.setValue("bytes=\(alreadyHave)-", forHTTPHeaderField: "Range")
        }

        let sink = try ChunkSink(partial: partial,
                                 alreadyHave: alreadyHave,
                                 onProgress: onProgress)
        try await sink.run(request: request)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    static func humanBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes > 1_000_000_000 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// Writes response chunks straight to disk.
///
/// `URLSession.bytes` yields one byte at a time, which is fine for a JSON reply
/// and hopeless for a multi-gigabyte model — the per-element overhead, not the
/// network, becomes the limit. A data-task delegate hands over whole chunks
/// instead.
private final class ChunkSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let handle: FileHandle
    private let onProgress: @Sendable (Downloader.Progress) -> Void
    private let lock = NSLock()
    private var written: Int64
    private var total: Int64 = -1
    private var startOffset: Int64
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Void, Error>?

    init(partial: URL,
         alreadyHave: Int64,
         onProgress: @escaping @Sendable (Downloader.Progress) -> Void) throws {
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: partial)
        self.written = alreadyHave
        self.startOffset = alreadyHave
        self.onProgress = onProgress
        super.init()
        try handle.seekToEnd()
    }

    func run(request: URLRequest) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(with: Downloader.DownloadError.badStatus(0))
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            break                       // resuming; keep what is on disk
        case 200:
            // The server ignored our range, so the bytes we have are useless.
            try? handle.truncate(atOffset: 0)
            lock.lock(); written = 0; startOffset = 0; lock.unlock()
        default:
            finish(with: Downloader.DownloadError.badStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        total = http.expectedContentLength > 0 ? http.expectedContentLength + startOffset : -1
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            finish(with: error)
            dataTask.cancel()
            return
        }
        lock.lock()
        written += Int64(data.count)
        let snapshot = Downloader.Progress(completed: written, total: total)
        let shouldReport = Date().timeIntervalSince(lastReport) > 0.2
        if shouldReport { lastReport = Date() }
        lock.unlock()

        if shouldReport { onProgress(snapshot) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.close()
        if let error {
            finish(with: error)
        } else {
            lock.lock()
            let snapshot = Downloader.Progress(completed: written, total: written)
            lock.unlock()
            onProgress(snapshot)
            finish(with: nil)
        }
    }

    private func finish(with error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}
