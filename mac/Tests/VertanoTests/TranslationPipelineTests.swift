import Foundation
import XCTest

@testable import StenoDrop

private enum FakeError: Error, Equatable {
    case boom
}

private actor FakeTranslationEngine: TranslationEngine {
    private(set) var calls: [(text: String, language: String)] = []
    var failFor: Set<String> = []

    func translateBatch(
        texts: [String],
        from source: Locale.Language?,
        to target: Locale.Language,
        onSubBatchCompleted: @escaping @Sendable (Int, Int) -> Void
    ) async -> [Int: Result<String, Error>] {
        let code = target.minimalIdentifier
        var results: [Int: Result<String, Error>] = [:]
        for (index, text) in texts.enumerated() {
            calls.append((text, code))
            results[index] =
                failFor.contains(code) ? .failure(FakeError.boom) : .success("[\(code)] \(text)")
        }
        return results
    }
}

final class TranslationPipelineTests: XCTestCase {
    func testStepsRouteEnglishToWhisperAndOthersToTextTranslate() {
        let steps = TranslationPipeline.steps(for: ["en", "fr", "ur"])
        let byLanguage = Dictionary(uniqueKeysWithValues: steps.map { ($0.language, $0.target) })
        XCTAssertEqual(byLanguage["en"], .whisperTranslate)
        XCTAssertEqual(byLanguage["fr"], .textTranslate("fr"))
        XCTAssertEqual(byLanguage["ur"], .textTranslate("ur"))
    }

    func testStepsAreSortedForDeterministicOrder() {
        let steps = TranslationPipeline.steps(for: ["ur", "en", "fr"])
        XCTAssertEqual(steps.map(\.language), ["en", "fr", "ur"])
    }

    func testEmptyTargetLanguagesProducesNoSteps() {
        XCTAssertTrue(TranslationPipeline.steps(for: []).isEmpty)
    }

    func testRunDispatchesEnglishToWhisperClosureNotEngine() async {
        let engine = FakeTranslationEngine()
        let outcomes = await TranslationPipeline.run(
            originalText: "hello",
            targetLanguages: ["en"],
            whisperTranslate: { "whisper-english-output" },
            engine: engine
        )
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].language, "en")
        if case .success(let text) = outcomes[0].result {
            XCTAssertEqual(text, "whisper-english-output")
        } else {
            XCTFail("expected success")
        }
        let calls = await engine.calls
        XCTAssertTrue(calls.isEmpty, "English must not go through the text-translation engine")
    }

    func testRunDispatchesOtherLanguagesToEngineWithOriginalText() async {
        let engine = FakeTranslationEngine()
        let outcomes = await TranslationPipeline.run(
            originalText: "hello world",
            targetLanguages: ["fr", "ur"],
            whisperTranslate: { XCTFail("must not be called"); return "" },
            engine: engine
        )
        XCTAssertEqual(outcomes.count, 2)
        let calls = await engine.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.text == "hello world" })
        XCTAssertEqual(Set(calls.map(\.language)), ["fr", "ur"])
    }

    func testOneLanguageFailingDoesNotAbortTheOthers() async {
        let engine = FakeTranslationEngine()
        await engine.setFailFor(["ur"])
        let outcomes = await TranslationPipeline.run(
            originalText: "hello",
            targetLanguages: ["fr", "ur"],
            whisperTranslate: { "" },
            engine: engine
        )
        let byLanguage = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.language, $0.result) })
        guard case .success = byLanguage["fr"] else { return XCTFail("fr should succeed") }
        guard case .failure = byLanguage["ur"] else { return XCTFail("ur should fail") }
    }

    func testWhisperTranslateFailureIsCapturedNotThrown() async {
        let engine = FakeTranslationEngine()
        let outcomes = await TranslationPipeline.run(
            originalText: "hello",
            targetLanguages: ["en"],
            whisperTranslate: { throw FakeError.boom },
            engine: engine
        )
        guard case .failure = outcomes[0].result else { return XCTFail("expected failure") }
    }
}

extension FakeTranslationEngine {
    func setFailFor(_ languages: Set<String>) { failFor = languages }
}
