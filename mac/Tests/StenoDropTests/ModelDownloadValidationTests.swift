import XCTest

@testable import StenoDrop

final class ModelDownloadValidationTests: XCTestCase {
    func testSuccessWhenStatusOKAndSizeAboveFloor() {
        let result = ModelDownloader.validate(
            status: 200, size: 500_000_000, tier: .efficient)
        XCTAssertNil(result)
    }

    func testFailsOnNonOKStatus() {
        let result = ModelDownloader.validate(
            status: 404, size: 500_000_000, tier: .efficient)
        XCTAssertEqual(result, "Download failed (HTTP 404). Try again.")
    }

    func testFailsWhenSizeBelowTierFloor() {
        let result = ModelDownloader.validate(
            status: 200, size: 100, tier: .efficient)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("incomplete"))
    }

    func testFloorIsPerTierNotGlobal() {
        // 500 MB clears the Efficient (small) floor but must fail the
        // Enhanced (medium) floor — floors are per-tier, not one constant.
        XCTAssertNil(ModelDownloader.validate(status: 200, size: 500_000_000, tier: .efficient))
        XCTAssertNotNil(ModelDownloader.validate(status: 200, size: 500_000_000, tier: .enhanced))
    }
}
