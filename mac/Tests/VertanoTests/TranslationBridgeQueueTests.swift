import Foundation
import Translation
import XCTest

@testable import StenoDrop

private enum FakeSessionError: Error, Equatable {
    case offline
}

/// Exercises the bridge's queue, correlation, and configuration-transition
/// logic with a fake fulfiller standing in for `TranslationSession` (which
/// cannot run in a SwiftPM test host). The view-side session closure is
/// deliberately out of scope — it is a thin adapter over `complete(_:with:)`.
final class TranslationBridgeQueueTests: XCTestCase {

    private func fulfilled(_ pairs: [(String?, String)]) -> [TranslationBridge.FulfilledTranslation] {
        pairs.map { TranslationBridge.FulfilledTranslation(clientIdentifier: $0.0, targetText: $0.1) }
    }

    private func successText(_ result: Result<String, Error>?) -> String? {
        if case .success(let text) = result { return text }
        return nil
    }

    private func isFailure(_ result: Result<String, Error>?) -> Bool {
        if case .failure = result { return true }
        return false
    }

    private func expectEventually(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
    }

    func testHeadsPublishInFIFOOrderAcrossMixedSingleAndBatchEntries() async throws {
        let bridge = TranslationBridge()
        let french = Locale.Language(identifier: "fr")

        let first = Task { try await bridge.translate("one", to: "de") }
        await expectEventually { bridge.currentRequest != nil }
        let second = Task { await bridge.translateBatch(texts: ["two-a", "two-b"], from: nil, to: french) }
        await expectEventually { bridge.pendingRequestCount == 2 }
        let third = Task { try await bridge.translate("three", to: "de") }
        await expectEventually { bridge.pendingRequestCount == 3 }

        let headA = try XCTUnwrap(bridge.currentRequest)
        XCTAssertEqual(headA.texts, ["one"])
        bridge.complete(headA.id, with: .success(fulfilled([("0", "eins")])))

        await expectEventually { bridge.currentRequest?.texts == ["two-a", "two-b"] }
        let headB = try XCTUnwrap(bridge.currentRequest)
        XCTAssertEqual(headB.targetLanguage, french)
        bridge.complete(headB.id, with: .success(fulfilled([("0", "deux-a"), ("1", "deux-b")])))

        await expectEventually { bridge.currentRequest?.texts == ["three"] }
        let headC = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(headC.id, with: .success(fulfilled([("0", "drei")])))

        let one = try await first.value
        XCTAssertEqual(one, "eins")
        let two = await second.value
        XCTAssertEqual(successText(two[0]), "deux-a")
        XCTAssertEqual(successText(two[1]), "deux-b")
        let three = try await third.value
        XCTAssertEqual(three, "drei")
        await expectEventually { bridge.currentRequest == nil }
    }

    func testSameTargetConsecutiveHeadsBothTransitionConfiguration() async throws {
        let bridge = TranslationBridge()
        let german = Locale.Language(identifier: "de")

        let first = Task { await bridge.translateBatch(texts: ["a"], from: nil, to: german) }
        await expectEventually { bridge.currentRequest?.texts == ["a"] }
        let second = Task { await bridge.translateBatch(texts: ["b"], from: nil, to: german) }
        await expectEventually { bridge.pendingRequestCount == 2 }

        let firstVersion = await MainActor.run { bridge.configuration?.version }
        XCTAssertNotNil(firstVersion)

        let headA = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(headA.id, with: .success(fulfilled([("0", "A")])))
        await expectEventually { bridge.currentRequest?.texts == ["b"] }

        let secondVersion = await MainActor.run { bridge.configuration?.version }
        let secondTarget = await MainActor.run { bridge.configuration?.target }
        XCTAssertNotNil(secondVersion)
        XCTAssertEqual(secondTarget, german)
        XCTAssertNotEqual(
            secondVersion, firstVersion,
            "same-target head must invalidate() the stored Configuration so .translationTask re-fires")

        let headB = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(headB.id, with: .success(fulfilled([("0", "B")])))
        _ = await first.value
        _ = await second.value
        await expectEventually { bridge.currentRequest == nil }
    }

    func testExplicitSourceLanguageReachesConfigurationAndNilStaysNil() async throws {
        let bridge = TranslationBridge()
        let urdu = Locale.Language(identifier: "ur")
        let english = Locale.Language(identifier: "en")

        let first = Task { await bridge.translateBatch(texts: ["a"], from: urdu, to: english) }
        await expectEventually { bridge.currentRequest != nil }
        XCTAssertEqual(bridge.currentRequest?.sourceLanguage, urdu)
        let firstSource = await MainActor.run { bridge.configuration?.source }
        XCTAssertEqual(firstSource, urdu)

        let second = Task { await bridge.translateBatch(texts: ["b"], from: nil, to: english) }
        await expectEventually { bridge.pendingRequestCount == 2 }
        let headA = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(headA.id, with: .success(fulfilled([("0", "A")])))
        await expectEventually { bridge.currentRequest?.texts == ["b"] }

        XCTAssertNil(bridge.currentRequest?.sourceLanguage)
        let secondSource = await MainActor.run { bridge.configuration?.source }
        XCTAssertNil(secondSource)

        let headB = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(headB.id, with: .success(fulfilled([("0", "B")])))
        _ = await first.value
        _ = await second.value
    }

    func testShuffledBatchResponsesCorrelateByClientIdentifierNotPosition() async throws {
        let bridge = TranslationBridge()
        let task = Task {
            await bridge.translateBatch(
                texts: ["a", "b", "c"], from: nil, to: Locale.Language(identifier: "de"))
        }
        await expectEventually { bridge.currentRequest != nil }
        let head = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(head.id, with: .success(fulfilled([("2", "C"), ("0", "A"), ("1", "B")])))

        let results = await task.value
        XCTAssertEqual(successText(results[0]), "A")
        XCTAssertEqual(successText(results[1]), "B")
        XCTAssertEqual(successText(results[2]), "C")
    }

    func testMissingResponseFailsThatChunkWhileOthersSucceed() async throws {
        let bridge = TranslationBridge()
        let task = Task {
            await bridge.translateBatch(
                texts: ["a", "b", "c"], from: nil, to: Locale.Language(identifier: "de"))
        }
        await expectEventually { bridge.currentRequest != nil }
        let head = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(head.id, with: .success(fulfilled([("2", "C"), ("0", "A")])))

        let results = await task.value
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(successText(results[0]), "A")
        XCTAssertTrue(isFailure(results[1]))
        XCTAssertEqual(successText(results[2]), "C")
    }

    func testBatchesSplitAt300AndCompletedSubBatchesSurviveALaterFailure() async throws {
        let bridge = TranslationBridge()
        let texts = (0..<301).map { "t\($0)" }
        let progress = ProgressRecorder()
        let task = Task {
            await bridge.translateBatch(
                texts: texts, from: nil, to: Locale.Language(identifier: "de"),
                onSubBatchCompleted: { progress.record($0, $1) })
        }

        await expectEventually { bridge.currentRequest?.texts.count == 300 }
        let headA = try XCTUnwrap(bridge.currentRequest)
        XCTAssertEqual(headA.texts.first, "t0")
        XCTAssertEqual(headA.texts.last, "t299")
        bridge.complete(
            headA.id, with: .success(fulfilled((0..<300).map { (String($0), "T\($0)") })))

        await expectEventually { bridge.currentRequest?.texts == ["t300"] }
        let headB = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(headB.id, with: .failure(FakeSessionError.offline))

        let results = await task.value
        XCTAssertEqual(results.count, 301)
        XCTAssertEqual(successText(results[0]), "T0")
        XCTAssertEqual(successText(results[299]), "T299")
        XCTAssertTrue(isFailure(results[300]), "failed sub-batch must not erase the completed one")
        XCTAssertEqual(progress.snapshot.map { "\($0.0)/\($0.1)" }, ["1/2", "2/2"])
    }

    func testSingleTranslateSurfacesSessionFailureAsThrownError() async throws {
        let bridge = TranslationBridge()
        let task = Task { try await bridge.translate("hello", to: "de") }
        await expectEventually { bridge.currentRequest != nil }
        let head = try XCTUnwrap(bridge.currentRequest)
        bridge.complete(head.id, with: .failure(FakeSessionError.offline))

        do {
            _ = try await task.value
            XCTFail("expected the sub-batch failure to throw")
        } catch let error as FakeSessionError {
            XCTAssertEqual(error, .offline)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Int, Int)] = []

    func record(_ completed: Int, _ total: Int) {
        lock.lock()
        events.append((completed, total))
        lock.unlock()
    }

    var snapshot: [(Int, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
