import Foundation

/// Translates already-transcribed text into a target language. English
/// never goes through this — it uses whisper's own native translate task
/// against the source audio instead (see `TranslationPipeline`).
///
/// The batch primitive returns per-index results instead of throwing: a
/// caption job with dozens of chunks must keep every successful translation
/// when a few fail (spec §5), which a bare `throws -> [String]` cannot
/// express. Every input index appears in the result — a chunk whose
/// response went missing surfaces as that index's individual `.failure`.
protocol TranslationEngine: Sendable {
    /// `onSubBatchCompleted` fires after each engine-internal sub-batch
    /// (completed count, total count) so callers can drive visible
    /// per-language progress while a large batch is in flight.
    func translateBatch(
        texts: [String],
        from source: Locale.Language?,
        to target: Locale.Language,
        onSubBatchCompleted: @escaping @Sendable (Int, Int) -> Void
    ) async -> [Int: Result<String, Error>]
}

enum TranslationEngineError: Error {
    /// The session returned no response correlated to this chunk's
    /// `clientIdentifier`; only that chunk fails, never the whole batch.
    case missingResponse
}

extension TranslationEngine {
    func translateBatch(
        texts: [String], from source: Locale.Language?, to target: Locale.Language
    ) async -> [Int: Result<String, Error>] {
        await translateBatch(texts: texts, from: source, to: target, onSubBatchCompleted: { _, _ in })
    }

    /// Single-string convenience over the batch primitive — keeps the audio
    /// pipeline's call shape (`TranslationPipeline.run`) unchanged.
    func translate(_ text: String, to languageCode: String) async throws -> String {
        let results = await translateBatch(
            texts: [text], from: nil, to: Locale.Language(identifier: languageCode))
        switch results[0] {
        case .success(let translated): return translated
        case .failure(let error): throw error
        case nil: throw TranslationEngineError.missingResponse
        }
    }
}

/// How a given target language's output is produced.
enum TranslationTarget: Equatable {
    /// English: re-run whisper against the source audio with `--translate`.
    /// Whisper only ever translates to English, so this is the one
    /// language that never touches `TranslationEngine`.
    case whisperTranslate
    /// Any other language: translate the already-produced original-language
    /// transcript text via `TranslationEngine`.
    case textTranslate(String)
}

/// Pure orchestration: given a set of requested target languages, decides
/// how each should be produced and runs them, without knowing anything
/// about whisper subprocesses or on-device translation sessions — those
/// are injected as closures/protocols so this is unit-testable without
/// hardware, a display, or a network connection.
enum TranslationPipeline {
    struct Outcome {
        let language: String
        let result: Result<String, Error>
    }

    /// Deterministic language → target-strategy mapping, sorted so job
    /// output order (and log/test output) never depends on `Set` iteration
    /// order.
    static func steps(for targetLanguages: Set<String>) -> [(language: String, target: TranslationTarget)] {
        targetLanguages.sorted().map { code in
            (code, code == "en" ? .whisperTranslate : .textTranslate(code))
        }
    }

    /// Runs every step independently — one language failing (e.g. a
    /// language pack isn't installed) must not block the others from
    /// producing their output files.
    static func run(
        originalText: String,
        targetLanguages: Set<String>,
        whisperTranslate: @Sendable () async throws -> String,
        engine: TranslationEngine
    ) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for step in steps(for: targetLanguages) {
            do {
                let text: String
                switch step.target {
                case .whisperTranslate:
                    text = try await whisperTranslate()
                case .textTranslate(let code):
                    text = try await engine.translate(originalText, to: code)
                }
                outcomes.append(Outcome(language: step.language, result: .success(text)))
            } catch {
                outcomes.append(Outcome(language: step.language, result: .failure(error)))
            }
        }
        return outcomes
    }
}
