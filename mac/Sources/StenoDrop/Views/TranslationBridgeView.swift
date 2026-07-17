import SwiftUI
import Translation

/// Invisible session host for `TranslationBridge` — mounted once in
/// `RootView` so it stays alive for the app's lifetime. `.translationTask`
/// re-runs its closure whenever `configuration` changes, i.e. whenever a
/// new pending request needs a different target language.
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
            // isolated" and trips the concurrency checker on the call
            // below (`translate` is a plain nonisolated instance method).
            .translationTask(configuration) { @Sendable session in
                guard let request = bridge.currentRequest else { return }
                do {
                    let response = try await session.translate(request.text)
                    bridge.complete(request.id, result: .success(response.targetText))
                } catch {
                    bridge.complete(request.id, result: .failure(error))
                }
            }
    }

    private var configuration: TranslationSession.Configuration? {
        guard let request = bridge.currentRequest,
            let target = Locale.Language(identifier: request.targetLanguageCode) as Locale.Language?
        else { return nil }
        return TranslationSession.Configuration(target: target)
    }
}
