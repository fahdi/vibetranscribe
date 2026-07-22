import Foundation
import Translation

/// `TranslationSession` (Apple's on-device Translation framework) cannot be
/// constructed directly — it only exists while a SwiftUI view hosting the
/// `.translationTask` modifier is in the hierarchy. `TranslationBridge`
/// lets background pipelines request translations with plain async/await;
/// `TranslationBridgeView`, mounted once in `RootView`, is the actual
/// session host and fulfills requests as they arrive.
///
/// Deliberately not `@MainActor`: capturing a MainActor-isolated object
/// inside `.translationTask`'s closure makes the compiler infer the whole
/// closure (including the `TranslationSession` it receives, which is not
/// Sendable) as MainActor-isolated, which then trips Swift 6's
/// region-isolation checker when the session is used. Mirrors the
/// `nonisolated(unsafe)` + `NSLock` pattern `WhisperEngine` already uses
/// for the same kind of cross-boundary shared state; only `Configuration`
/// (not Sendable) is confined to the main actor, where a single consumer
/// task owns every head publication — a fire-and-forget
/// `Task { @MainActor }` per mutation could publish heads out of order.
///
/// `.translationTask` only re-fires when the Configuration *value* changes,
/// so two consecutive same-target heads need `invalidate()` on the STORED
/// configuration to bump its version; rebuilding a fresh Configuration
/// (as a computed property would per render) resets the version and wedges
/// the second request forever.
///
/// NOT covered by the automated test suite: the real `TranslationSession`
/// doesn't run in a SwiftPM test host — tests drive `complete(_:with:)`
/// directly; session behavior is on the manual on-hardware checklist.
final class TranslationBridge: ObservableObject, TranslationEngine, @unchecked Sendable {
    static let shared = TranslationBridge()

    /// Cap per `translations(from:)` call; larger inputs are sequenced as
    /// multiple queue entries so a failure only loses one sub-batch (§5).
    static let subBatchLimit = 300

    struct PendingRequest: Identifiable, Sendable {
        let id = UUID()
        let texts: [String]
        let sourceLanguage: Locale.Language?
        let targetLanguage: Locale.Language
    }

    /// Sendable projection of `TranslationSession.Response` so tests can
    /// drive the queue with a fake fulfiller and the view stays a thin
    /// adapter over the real session.
    struct FulfilledTranslation: Sendable {
        let clientIdentifier: String?
        let targetText: String
    }

    private struct Entry {
        let request: PendingRequest
        let continuation: CheckedContinuation<[Int: Result<String, Error>], Never>
    }

    private let lock = NSLock()
    private var queue: [Entry] = []
    private let signal: AsyncStream<Void>.Continuation

    /// Read by `TranslationBridgeView`'s session closure to know which
    /// request the current session invocation is for. Written only by the
    /// single main-actor consumer, so publications can never reorder.
    @Published private(set) var currentRequest: PendingRequest?

    /// The one Configuration whose value transitions drive
    /// `.translationTask`. Stored — never recomputed per render — so
    /// `invalidate()` can bump the version in place for same-target
    /// consecutive heads. Mutated exclusively by the consumer task.
    @MainActor @Published private(set) var configuration: TranslationSession.Configuration?

    @MainActor private var lastPublishedID: UUID?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        signal = continuation
        Task { @MainActor [weak self] in
            for await _ in stream {
                self?.publishHead()
            }
        }
    }

    deinit { signal.finish() }

    var pendingRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    nonisolated func translateBatch(
        texts: [String],
        from source: Locale.Language?,
        to target: Locale.Language,
        onSubBatchCompleted: @escaping @Sendable (Int, Int) -> Void
    ) async -> [Int: Result<String, Error>] {
        guard !texts.isEmpty else { return [:] }
        let subBatchCount = (texts.count + Self.subBatchLimit - 1) / Self.subBatchLimit
        var merged: [Int: Result<String, Error>] = [:]
        var offset = 0
        var completed = 0
        while offset < texts.count {
            let upper = min(offset + Self.subBatchLimit, texts.count)
            let subResults = await enqueue(
                texts: Array(texts[offset..<upper]), source: source, target: target)
            for (index, result) in subResults {
                merged[offset + index] = result
            }
            offset = upper
            completed += 1
            onSubBatchCompleted(completed, subBatchCount)
        }
        return merged
    }

    /// Called by `TranslationBridgeView` (or a test's fake fulfiller) once
    /// a session finishes — or fails — the current head-of-queue request.
    /// A failure fails every chunk of that sub-batch only; earlier
    /// sub-batches already resumed with their results.
    func complete(_ id: UUID, with outcome: Result<[FulfilledTranslation], Error>) {
        lock.lock()
        guard let head = queue.first, head.request.id == id else {
            lock.unlock()
            return
        }
        queue.removeFirst()
        lock.unlock()
        head.continuation.resume(
            returning: Self.correlate(outcome, count: head.request.texts.count))
        signal.yield(())
    }

    /// Matches responses to input indices by `clientIdentifier` — never by
    /// array position, which `translations(from:)` does not guarantee.
    static func correlate(
        _ outcome: Result<[FulfilledTranslation], Error>, count: Int
    ) -> [Int: Result<String, Error>] {
        var results: [Int: Result<String, Error>] = [:]
        switch outcome {
        case .failure(let error):
            for index in 0..<count {
                results[index] = .failure(error)
            }
        case .success(let responses):
            for response in responses {
                guard let identifier = response.clientIdentifier,
                    let index = Int(identifier), (0..<count).contains(index)
                else { continue }
                results[index] = .success(response.targetText)
            }
            for index in 0..<count where results[index] == nil {
                results[index] = .failure(TranslationEngineError.missingResponse)
            }
        }
        return results
    }

    private nonisolated func enqueue(
        texts: [String], source: Locale.Language?, target: Locale.Language
    ) async -> [Int: Result<String, Error>] {
        await withCheckedContinuation { continuation in
            let request = PendingRequest(
                texts: texts, sourceLanguage: source, targetLanguage: target)
            lock.lock()
            queue.append(Entry(request: request, continuation: continuation))
            lock.unlock()
            signal.yield(())
        }
    }

    @MainActor private func publishHead() {
        lock.lock()
        let head = queue.first?.request
        lock.unlock()
        // Signals coalesce over shared state; a head already published must
        // not transition the configuration a second time (it would spawn a
        // duplicate session for the same request).
        guard head?.id != lastPublishedID else { return }
        lastPublishedID = head?.id
        currentRequest = head
        guard let head else {
            configuration = nil
            return
        }
        if var existing = configuration,
            existing.target == head.targetLanguage,
            existing.source == head.sourceLanguage
        {
            existing.invalidate()
            configuration = existing
        } else {
            configuration = TranslationSession.Configuration(
                source: head.sourceLanguage, target: head.targetLanguage)
        }
    }
}
