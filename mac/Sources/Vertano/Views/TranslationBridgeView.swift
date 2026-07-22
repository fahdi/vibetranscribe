import SwiftUI
import Translation

/// Invisible session host for `TranslationBridge` — mounted once in
/// `RootView` so it stays alive for the app's lifetime. `.translationTask`
/// re-runs its closure whenever the bridge's STORED `configuration`
/// transitions, which the bridge's main-actor consumer guarantees happens
/// exactly once per head-of-queue request (invalidating in place for
/// same-target consecutive heads). The configuration must never be a
/// computed property here: rebuilding it per render resets its version and
/// the second of two same-target requests would never fire.
struct TranslationBridgeView: View {
    @ObservedObject var bridge: TranslationBridge

    var body: some View {
        // Captured as a plain local before entering the @Sendable closure
        // below: `self.bridge` is a MainActor-isolated View property
        // (the @ObservedObject wrapper enforces that regardless of the
        // wrapped class's own isolation), but the TranslationBridge
        // instance itself is `@unchecked Sendable` — this local rebinding
        // is what lets the closure capture it without a MainActor hop.
        let bridge = bridge
        return Color.clear
            .frame(width: 0, height: 0)
            // Explicitly @Sendable: without it, a closure literal inside a
            // SwiftUI `body` (MainActor by protocol requirement) infers
            // MainActor isolation from its enclosing context, which then
            // makes the non-Sendable `session` parameter "main actor
            // isolated" and trips the concurrency checker on the calls
            // below.
            .translationTask(bridge.configuration) { @Sendable session in
                guard let request = bridge.currentRequest else { return }
                do {
                    let fulfilled: [TranslationBridge.FulfilledTranslation]
                    if request.texts.count == 1 {
                        let response = try await session.translate(request.texts[0])
                        fulfilled = [
                            .init(clientIdentifier: "0", targetText: response.targetText)
                        ]
                    } else {
                        let batch = request.texts.enumerated().map { index, text in
                            TranslationSession.Request(
                                sourceText: text, clientIdentifier: String(index))
                        }
                        fulfilled = try await session.translations(from: batch).map {
                            .init(clientIdentifier: $0.clientIdentifier, targetText: $0.targetText)
                        }
                    }
                    if Task.isCancelled { return }
                    bridge.complete(request.id, with: .success(fulfilled))
                } catch {
                    // A cancelled task means the configuration moved on to a
                    // newer head; completing would fail the wrong request.
                    if Task.isCancelled || error is CancellationError { return }
                    bridge.complete(request.id, with: .failure(error))
                }
            }
    }
}
