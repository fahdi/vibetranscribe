import Foundation

/// Translates already-transcribed text into a target language. English
/// never goes through this — it uses whisper's own native translate task
/// against the source audio instead (see `TranslationPipeline`).
protocol TranslationEngine: Sendable {
    func translate(_ text: String, to languageCode: String) async throws -> String
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
