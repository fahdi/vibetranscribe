import Foundation
import Translation

/// `TranslationSession` (Apple's on-device Translation framework) cannot be
/// constructed directly — it only exists while a SwiftUI view hosting the
/// `.translationTask` modifier is in the hierarchy. `TranslationBridge`
/// lets `JobQueue`'s background pipeline request a translation with plain
/// async/await; `TranslationBridgeView`, mounted once in `RootView`, is the
/// actual session host and fulfills requests as they arrive.
///
/// Deliberately not `@MainActor`: capturing a MainActor-isolated object
/// inside `.translationTask`'s closure makes the compiler infer the whole
/// closure (including the `TranslationSession` it receives, which is not
/// Sendable) as MainActor-isolated, which then trips Swift 6's
/// region-isolation checker when the session is used. Mirrors the
/// `nonisolated(unsafe)` + `NSLock` pattern `WhisperEngine` already uses
/// for the same kind of cross-boundary shared state; only the `@Published`
/// write for SwiftUI hops to the main actor.
///
/// NOT covered by the automated test suite: `TranslationSession` doesn't
/// run in the Simulator or a SwiftPM test host. Verified manually on a
/// real Mac (see the translation design spec).
final class TranslationBridge: ObservableObject, TranslationEngine, @unchecked Sendable {
    static let shared = TranslationBridge()

    struct PendingRequest: Identifiable, Sendable {
        let id = UUID()
        let text: String
        let targetLanguageCode: String
    }

    private struct Entry {
        let request: PendingRequest
        let continuation: CheckedContinuation<String, Error>
    }

    private let lock = NSLock()
    private var queue: [Entry] = []

    /// Read by `TranslationBridgeView` to build the session `Configuration`
    /// and to know which request the current session invocation is for.
    @Published private(set) var currentRequest: PendingRequest?

    nonisolated func translate(_ text: String, to languageCode: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(text: text, targetLanguageCode: languageCode)
            lock.lock()
            queue.append(Entry(request: request, continuation: continuation))
            let isOnlyEntry = queue.count == 1
            lock.unlock()
            if isOnlyEntry { publishHead() }
        }
    }

    /// Called by `TranslationBridgeView` once a session finishes (or fails)
    /// translating the current head-of-queue request.
    func complete(_ id: UUID, result: Result<String, Error>) {
        lock.lock()
        guard let head = queue.first, head.request.id == id else {
            lock.unlock()
            return
        }
        queue.removeFirst()
        lock.unlock()
        head.continuation.resume(with: result)
        publishHead()
    }

    private func publishHead() {
        lock.lock()
        let head = queue.first?.request
        lock.unlock()
        Task { @MainActor in self.currentRequest = head }
    }
}
