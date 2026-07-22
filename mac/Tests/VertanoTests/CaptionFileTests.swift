import XCTest

@testable import StenoDrop

final class CaptionFileTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Real fixtures

    func testRealYtDlpFixtureParses() throws {
        let file = try CaptionFile.parse(fixtureData("real-yt-dlp-rollup.en.vtt"), format: .vtt)
        XCTAssertEqual(file.cues.count, 103)
        XCTAssertEqual(file.language, "en")
        XCTAssertEqual(file.skippedBlockCount, 0)
        XCTAssertTrue(file.warnings.isEmpty)

        let first = file.cues[0]
        XCTAssertEqual(first.startMs, 320)
        XCTAssertEqual(first.endMs, 18790)
        XCTAssertEqual(first.lines.map(\.text), [" ", "[Music]"])
        XCTAssertFalse(first.lines[1].hadInlineTimestamps)

        let third = file.cues[2]
        XCTAssertEqual(third.startMs, 18800)
        XCTAssertEqual(third.endMs, 21790)
        XCTAssertEqual(third.lines[1].text, "We're no strangers to")
        XCTAssertTrue(third.lines[1].hadInlineTimestamps)
        XCTAssertFalse(third.lines[0].hadInlineTimestamps)

        let last = try XCTUnwrap(file.cues.last)
        XCTAssertEqual(last.startMs, 206_840)
        XCTAssertEqual(last.endMs, 211_879)
        XCTAssertEqual(last.lines[0].text, "make you cry. Never going to say")
        XCTAssertEqual(last.lines[1].text, "goodbye. Never going to say goodbye.")
        XCTAssertTrue(last.lines[1].hadInlineTimestamps)
    }

    func testRealCSpanFixtureParsesBestEffort() throws {
        let file = try CaptionFile.parse(fixtureData("real-cspan-rollup-sample.vtt"), format: .vtt)
        XCTAssertEqual(file.cues.count, 9)
        XCTAssertEqual(file.language, "en")
        XCTAssertEqual(file.skippedBlockCount, 8)
        XCTAssertTrue(file.warnings.contains { $0.contains("8") }, "skipped-block warning must carry the count")

        // Building cue whose tagged line chunks mid-word (TH<c>E </c><c>SE</c>…).
        let building = file.cues[2]
        XCTAssertEqual(building.startMs, 235_334)
        XCTAssertEqual(building.endMs, 237_236)
        XCTAssertEqual(building.lines[0].text, "THE SERGEANT AT ARMS: MADAM")
        XCTAssertEqual(building.lines[1].text, "SPEAKER, THE VICE PRESIDENT AND ")
        XCTAssertTrue(building.lines[1].hadInlineTimestamps)

        // Long static cue: end time crosses into a later minute.
        let long = file.cues[4]
        XCTAssertEqual(long.startMs, 237_369)
        XCTAssertEqual(long.endMs, 469_535)
        XCTAssertEqual(long.lines[1].text, "THE UNITED STATES SENATE.")
    }

    // MARK: - Decode ladder

    func testUTF16LEBOMSRTDecodes() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\ncafé naïve\n"
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(srt.data(using: .utf16LittleEndian)))
        let file = try CaptionFile.parse(data, format: .srt)
        XCTAssertEqual(file.cues.count, 1)
        XCTAssertEqual(file.cues[0].lines[0].text, "café naïve")
        XCTAssertTrue(file.warnings.isEmpty)
    }

    func testUTF16BEBOMSRTDecodes() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\ncafé\n"
        var data = Data([0xFE, 0xFF])
        data.append(try XCTUnwrap(srt.data(using: .utf16BigEndian)))
        let file = try CaptionFile.parse(data, format: .srt)
        XCTAssertEqual(file.cues[0].lines[0].text, "café")
        XCTAssertTrue(file.warnings.isEmpty)
    }

    func testUTF8BOMIsStrippedPostDecode() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nhello\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(try XCTUnwrap(srt.data(using: .utf8)))
        let file = try CaptionFile.parse(data, format: .srt)
        XCTAssertEqual(file.cues.count, 1)
        XCTAssertFalse(file.cues[0].lines[0].text.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(file.warnings.isEmpty)
    }

    func testWindows1252FallbackDecodesWithWarning() throws {
        // "café" and "über" with CP1252 single-byte accents — invalid as UTF-8.
        var data = Data()
        data.append(contentsOf: Array("1\n00:00:01,000 --> 00:00:02,000\ncaf".utf8))
        data.append(0xE9) // é
        data.append(contentsOf: Array("\n".utf8))
        data.append(0xFC) // ü
        data.append(contentsOf: Array("ber\n".utf8))
        let file = try CaptionFile.parse(data, format: .srt)
        XCTAssertEqual(file.cues[0].lines.map(\.text), ["café", "über"])
        XCTAssertTrue(file.warnings.contains { $0.contains("Windows-1252") })
    }

    // MARK: - Timestamps

    func testSRTTimestampRoundTripIsIdentity() {
        for stamp in ["00:00:00,000", "01:02:03,456", "23:59:59,999", "100:00:00,001"] {
            let ms = CaptionFile.parseTimestamp(stamp, format: .srt)
            XCTAssertNotNil(ms, stamp)
            XCTAssertEqual(CaptionFile.formatTimestamp(ms!, format: .srt), stamp)
        }
    }

    func testVTTTimestampRoundTripIsIdentity() {
        for stamp in ["00:00:00.320", "00:03:55.201", "01:02:03.456", "100:00:00.001"] {
            let ms = CaptionFile.parseTimestamp(stamp, format: .vtt)
            XCTAssertNotNil(ms, stamp)
            XCTAssertEqual(CaptionFile.formatTimestamp(ms!, format: .vtt), stamp)
        }
    }

    func testVTTHoursAreOptionalOnParse() {
        XCTAssertEqual(CaptionFile.parseTimestamp("01:02.500", format: .vtt), 62_500)
        XCTAssertEqual(CaptionFile.parseTimestamp("00:01:02.500", format: .vtt), 62_500)
    }

    func testFractionalSecondsRoundNeverTruncate() {
        XCTAssertEqual(CaptionFile.parseTimestamp("00:00:01.5", format: .vtt), 1500)
        XCTAssertEqual(CaptionFile.parseTimestamp("00:00:01.0006", format: .vtt), 1001)
    }

    func testWrongSeparatorRejectedPerFormat() {
        XCTAssertNil(CaptionFile.parseTimestamp("00:00:01.000", format: .srt))
        XCTAssertNil(CaptionFile.parseTimestamp("00:00:01,000", format: .vtt))
    }

    // MARK: - Line endings and EOF

    func testCRLFAndBareCRNormalized() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nfirst\r\r2\r00:00:02,000 --> 00:00:03,000\rsecond"
        let file = try CaptionFile.parse(Data(srt.utf8), format: .srt)
        XCTAssertEqual(file.cues.count, 2)
        XCTAssertEqual(file.cues[0].lines[0].text, "first")
        XCTAssertEqual(file.cues[1].lines[0].text, "second")
    }

    func testEOFTerminatesFinalBlockWithoutTrailingNewline() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nonly cue"
        let file = try CaptionFile.parse(Data(srt.utf8), format: .srt)
        XCTAssertEqual(file.cues.count, 1)
        XCTAssertEqual(file.cues[0].lines[0].text, "only cue")
    }

    // MARK: - VTT grammar

    func testVTTHeaderWithTrailingTextTolerated() throws {
        let vtt = "WEBVTT - generated by someone\n\n00:00:01.000 --> 00:00:02.000\nhi\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues.count, 1)
        XCTAssertNil(file.language)
    }

    func testVTTHeaderBlockConsumedAndLanguageCaptured() throws {
        let vtt = "WEBVTT\nKind: captions\nLanguage: ur\n\n00:00:01.000 --> 00:00:02.000\nhi\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.language, "ur")
        XCTAssertEqual(file.cues.count, 1)
        XCTAssertEqual(file.skippedBlockCount, 0)
    }

    func testNoteStyleRegionBlocksSkippedSilently() throws {
        let vtt = """
            WEBVTT

            NOTE this is a comment
            spanning two lines

            STYLE
            ::cue { color: red }

            REGION
            id:one

            00:00:01.000 --> 00:00:02.000
            hi

            """
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues.count, 1)
        XCTAssertEqual(file.skippedBlockCount, 0)
        XCTAssertTrue(file.warnings.isEmpty)
    }

    func testCueIdentifiersAndSettingsParsedPast() throws {
        let vtt = """
            WEBVTT

            intro cue
            00:00:01.000 --> 00:00:02.000 align:start position:0%
            hi

            """
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues.count, 1)
        XCTAssertEqual(file.cues[0].startMs, 1000)
        XCTAssertEqual(file.cues[0].endMs, 2000)
        XCTAssertEqual(file.cues[0].lines.map(\.text), ["hi"])
    }

    // MARK: - Tag stripping

    func testMidWordTagSpansDeletedByteForByte() throws {
        let raw = "TH<00:03:54.366><c>E </c><00:03:54.399><c>SE</c><00:03:54.433><c>RG</c><00:03:54.466><c>EA</c><00:03:54.500><c>NT</c><00:03:54.533><c> A</c><00:03:54.566><c>T </c><00:03:54.600><c>AR</c><00:03:54.633><c>MS</c><00:03:54.666><c>: </c><00:03:54.700><c>MA</c><00:03:54.733><c>DA</c><00:03:54.766><c>M</c><00:03:55.101><c> </c>"
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n\(raw)\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues[0].lines[0].text, "THE SERGEANT AT ARMS: MADAM ")
        XCTAssertTrue(file.cues[0].lines[0].hadInlineTimestamps)
    }

    func testStyleTagsStrippedWithoutTimestampFlag() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<i>hello</i> <b>world</b>\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues[0].lines[0].text, "hello world")
        XCTAssertFalse(file.cues[0].lines[0].hadInlineTimestamps)
    }

    func testRubyAnnotationDropped() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<ruby>漢<rt>かん</rt></ruby>字\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues[0].lines[0].text, "漢字")
    }

    func testVoiceTagBecomesSpeakerPrefix() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v Fred Rogers>Hello there</v>\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        let line = file.cues[0].lines[0]
        XCTAssertEqual(line.text, "Fred Rogers: Hello there")
        XCTAssertEqual(line.speakerPrefix, "Fred Rogers: ")
    }

    func testLineWithoutVoiceTagHasNoSpeakerPrefix() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nplain line\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertNil(file.cues[0].lines[0].speakerPrefix)
    }

    // MARK: - Entities

    func testEntitiesDecodedOnParse() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nA &amp; B &lt;c&gt; &#65;&#x42;\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues[0].lines[0].text, "A & B <c> AB")
    }

    func testEntityDecodeHappensAfterTagStripping() throws {
        // "&lt;c&gt;" must survive as literal text, never be treated as a tag.
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nkeep &lt;c&gt; literal\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues[0].lines[0].text, "keep <c> literal")
    }

    func testDirectionalAndNbspEntitiesDecoded() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\na&nbsp;b&lrm;c&rlm;d\n"
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(file.cues[0].lines[0].text, "a\u{00A0}b\u{200E}c\u{200F}d")
    }

    // MARK: - Emptiness predicate

    func testEmptinessPredicate() {
        XCTAssertTrue(CaptionFile.isEffectivelyEmpty(""))
        XCTAssertTrue(CaptionFile.isEffectivelyEmpty(" "))
        XCTAssertTrue(CaptionFile.isEffectivelyEmpty(" \t "))
        XCTAssertTrue(CaptionFile.isEffectivelyEmpty("\u{00A0}"))
        XCTAssertTrue(CaptionFile.isEffectivelyEmpty("&nbsp;"))
        XCTAssertTrue(CaptionFile.isEffectivelyEmpty("\u{200B}\u{200E}\u{200F}"))
        XCTAssertTrue(CaptionFile.isEffectivelyEmpty("&lrm;&rlm;"))
        XCTAssertFalse(CaptionFile.isEffectivelyEmpty("a"))
        XCTAssertFalse(CaptionFile.isEffectivelyEmpty("\u{00A0}x"))
        XCTAssertFalse(CaptionFile.isEffectivelyEmpty("[Music]"))
    }

    // MARK: - Malformed input

    func testMalformedBlockSkippedBetweenValidCues() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,000
            first

            this block has no timestamp line
            at all

            2
            00:00:03,000 --> 00:00:04,000
            second

            """
        let file = try CaptionFile.parse(Data(srt.utf8), format: .srt)
        XCTAssertEqual(file.cues.count, 2)
        XCTAssertEqual(file.skippedBlockCount, 1)
        XCTAssertTrue(file.warnings.contains { $0.contains("1") })
    }

    func testZeroValidCuesThrowsDistinctly() {
        let garbage = Data("not a caption file\n\nat all\n".utf8)
        XCTAssertThrowsError(try CaptionFile.parse(garbage, format: .srt)) { error in
            XCTAssertEqual(error as? CaptionFileError, .noValidCues)
        }
        XCTAssertThrowsError(try CaptionFile.parse(Data(), format: .vtt)) { error in
            XCTAssertEqual(error as? CaptionFileError, .noValidCues)
        }
    }

    // MARK: - Serialization

    func testSRTRoundTripIdentity() throws {
        let srt = """
            1
            00:00:01,000 --> 00:00:02,500
            Hello there

            2
            00:00:02,500 --> 00:00:04,000
            Second cue
            line two

            """
        let file = try CaptionFile.parse(Data(srt.utf8), format: .srt)
        XCTAssertEqual(CaptionFile.serialize(cues: file.cues, format: .srt), srt)
    }

    func testVTTRoundTripIdentity() throws {
        let vtt = """
            WEBVTT
            Language: en

            00:00:01.000 --> 00:00:02.500
            Hello there

            00:00:02.500 --> 00:00:04.000
            Second cue
            line two

            """
        let file = try CaptionFile.parse(Data(vtt.utf8), format: .vtt)
        XCTAssertEqual(
            CaptionFile.serialize(cues: file.cues, format: .vtt, language: file.language),
            vtt
        )
    }

    func testSRTIndicesIgnoredOnParseAndRegeneratedOnWrite() throws {
        let srt = "7\n00:00:01,000 --> 00:00:02,000\nfirst\n\n42\n00:00:03,000 --> 00:00:04,000\nsecond\n"
        let file = try CaptionFile.parse(Data(srt.utf8), format: .srt)
        let out = CaptionFile.serialize(cues: file.cues, format: .srt)
        XCTAssertTrue(out.hasPrefix("1\n00:00:01,000"))
        XCTAssertTrue(out.contains("\n\n2\n00:00:03,000"))
        XCTAssertFalse(out.contains("42"))
    }

    func testVTTWriteReEscapesAmpersandAndLessThan() {
        let cues = [
            Cue(
                startMs: 1000,
                endMs: 2000,
                lines: [CueLine(text: "AT&T <hello> done", hadInlineTimestamps: false)]
            )
        ]
        let out = CaptionFile.serialize(cues: cues, format: .vtt)
        XCTAssertTrue(out.contains("AT&amp;T &lt;hello> done"))
        let srtOut = CaptionFile.serialize(cues: cues, format: .srt)
        XCTAssertTrue(srtOut.contains("AT&T <hello> done"))
    }

    func testSerializedOutputIsUTF8LFNoBOM() {
        let cues = [Cue(startMs: 0, endMs: 1000, lines: [CueLine(text: "hé", hadInlineTimestamps: false)])]
        let out = CaptionFile.serialize(cues: cues, format: .vtt)
        XCTAssertFalse(out.hasPrefix("\u{FEFF}"))
        XCTAssertFalse(out.contains("\r"))
        XCTAssertTrue(out.hasSuffix("\n"))
    }
}
