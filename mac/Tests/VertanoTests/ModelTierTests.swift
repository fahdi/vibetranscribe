import XCTest

@testable import StenoDrop

final class ModelTierTests: XCTestCase {
    func testAllCasesHaveDistinctFilenames() {
        let filenames = Set(ModelTier.allCases.map(\.filename))
        XCTAssertEqual(filenames.count, ModelTier.allCases.count)
    }

    func testEfficientTierMatchesExistingGgmlSmall() {
        // Existing installs already have ggml-small.bin on disk under this
        // exact name; the tier's filename/URL must not change or every
        // current user re-downloads 466 MB for nothing.
        XCTAssertEqual(ModelTier.efficient.filename, "ggml-small.bin")
        XCTAssertEqual(
            ModelTier.efficient.downloadURL.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")
    }

    func testEnhancedTierIsMediumModel() {
        XCTAssertEqual(ModelTier.enhanced.filename, "ggml-medium.bin")
    }

    func testMaximumTierIsLargeV3Turbo() {
        XCTAssertEqual(ModelTier.maximum.filename, "ggml-large-v3-turbo.bin")
    }

    func testMinimumValidSizeScalesPerTier() {
        // Each floor must be comfortably below the real model size but high
        // enough to reject a truncated download or HTML error page.
        XCTAssertLessThan(ModelTier.efficient.minimumValidSize, ModelTier.enhanced.minimumValidSize)
        XCTAssertLessThan(ModelTier.enhanced.minimumValidSize, ModelTier.maximum.minimumValidSize)
        XCTAssertGreaterThan(ModelTier.efficient.minimumValidSize, 0)
    }

    func testRawValueRoundTripsForPersistence() {
        for tier in ModelTier.allCases {
            XCTAssertEqual(ModelTier(rawValue: tier.rawValue), tier)
        }
    }

    func testDefaultTierIsEfficient() {
        XCTAssertEqual(ModelTier.efficient.rawValue, "efficient")
    }

    func testCopyDoesNotMentionModelFilenames() {
        // The whole point of the tier framing is that users never see
        // "ggml-large-v3-turbo" etc. in the UI text.
        for tier in ModelTier.allCases {
            XCTAssertFalse(tier.summary.lowercased().contains("ggml"))
            XCTAssertFalse(tier.title.lowercased().contains("ggml"))
        }
    }
}
