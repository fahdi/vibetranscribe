import XCTest

@testable import StenoDrop

final class JobStatusTests: XCTestCase {

    // The quit guard (StenoDropApp.applicationShouldTerminate) depends on
    // isActive being true for every in-flight state — a translating caption
    // job must block quit exactly like a transcribing audio job.
    func testTranslatingIsActive() {
        XCTAssertTrue(
            JobStatus.translating(language: "French", current: 1, total: 3).isActive)
    }

    func testActiveStatesAreExactlyTheInFlightOnes() {
        XCTAssertFalse(JobStatus.queued.isActive)
        XCTAssertTrue(JobStatus.converting.isActive)
        XCTAssertTrue(JobStatus.transcribing.isActive)
        XCTAssertFalse(JobStatus.done.isActive)
        XCTAssertFalse(JobStatus.doneWithWarning("w").isActive)
        XCTAssertFalse(JobStatus.failed("e").isActive)
    }

    func testTranslatingIsNotFinished() {
        XCTAssertFalse(
            JobStatus.translating(language: "Urdu", current: 0, total: 1).isFinished)
        XCTAssertTrue(JobStatus.done.isFinished)
        XCTAssertTrue(JobStatus.doneWithWarning("w").isFinished)
        XCTAssertTrue(JobStatus.failed("e").isFinished)
        XCTAssertFalse(JobStatus.queued.isFinished)
    }

    func testTranslatingLabelShowsLanguageAndProgress() {
        let label = JobStatus.translating(language: "French", current: 2, total: 5)
            .label(for: .captions)
        XCTAssertTrue(label.contains("French"))
        XCTAssertTrue(label.contains("2"))
        XCTAssertTrue(label.contains("5"))
    }

    // "Done (not saved)" describes the audio failure mode (transcript
    // couldn't be written); caption jobs commonly finish with notes while
    // every file saved fine.
    func testDoneWithWarningLabelIsJobKindAware() {
        let status = JobStatus.doneWithWarning("English skipped")
        XCTAssertEqual(status.label(for: .audio), "Done (not saved)")
        XCTAssertNotEqual(status.label(for: .captions), "Done (not saved)")
    }

    func testTranscribingLabelIsJobKindAware() {
        XCTAssertEqual(JobStatus.transcribing.label(for: .audio), "Transcribing")
        XCTAssertNotEqual(JobStatus.transcribing.label(for: .captions), "Transcribing")
    }
}
