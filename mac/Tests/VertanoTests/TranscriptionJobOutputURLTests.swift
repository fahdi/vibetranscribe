import XCTest

@testable import StenoDrop

final class TranscriptionJobOutputURLTests: XCTestCase {
    func testNilLanguageReturnsTheOriginalOutputURLUnchanged() {
        let source = URL(fileURLWithPath: "/tmp/song.mp3")
        let output = URL(fileURLWithPath: "/tmp/song.txt")
        let job = TranscriptionJob(sourceURL: source, outputURL: output)
        XCTAssertEqual(job.outputURL(forLanguage: nil), output)
    }

    func testLanguageInsertsCodeBeforeExtension() {
        let source = URL(fileURLWithPath: "/tmp/song.mp3")
        let output = URL(fileURLWithPath: "/tmp/song.txt")
        let job = TranscriptionJob(sourceURL: source, outputURL: output)
        XCTAssertEqual(job.outputURL(forLanguage: "en").path, "/tmp/song.en.txt")
        XCTAssertEqual(job.outputURL(forLanguage: "fr").path, "/tmp/song.fr.txt")
    }

    func testLanguageInsertionSurvivesCollisionDisambiguatedBaseName() {
        // outputURL(for:) in JobQueue falls back to "song.mp3.txt" when
        // another queued source already claims "song.txt".
        let source = URL(fileURLWithPath: "/tmp/song.mp3")
        let output = URL(fileURLWithPath: "/tmp/song.mp3.txt")
        let job = TranscriptionJob(sourceURL: source, outputURL: output)
        XCTAssertEqual(job.outputURL(forLanguage: "en").path, "/tmp/song.mp3.en.txt")
    }
}
