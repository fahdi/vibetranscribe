import Foundation

@MainActor
final class ModelDownloader: NSObject, ObservableObject {
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var error: String?

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    func start() {
        guard !isDownloading else { return }
        error = nil
        progress = 0
        isDownloading = true
        try? FileManager.default.createDirectory(
            at: WhisperEngine.modelsDirectory, withIntermediateDirectories: true)
        task = session.downloadTask(with: WhisperEngine.modelURL)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        isDownloading = false
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.progress = fraction }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move synchronously — `location` is deleted when this method returns.
        var moveError: String?
        do {
            let dest = WhisperEngine.modelPath
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            moveError = error.localizedDescription
        }
        Task { @MainActor in
            self.isDownloading = false
            self.progress = 1
            self.error = moveError
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            self.isDownloading = false
            self.error = error.localizedDescription
        }
    }
}
