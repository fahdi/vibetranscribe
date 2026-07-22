import XCTest

@testable import StenoDrop

final class CaptionChunkingTests: XCTestCase {

    private func cue(_ startMs: Int, _ endMs: Int, _ text: String) -> Cue {
        Cue(startMs: startMs, endMs: endMs, lines: [CueLine(text: text, hadInlineTimestamps: false)])
    }

    private let english = Locale.Language(identifier: "en")

    // MARK: - Chunking: gap boundaries

    func testGapAtOrAboveEpsilonSplitsChunks() {
        let cues = [cue(0, 1000, "we shall fight"), cue(2000, 3000, "on the beaches")]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<1, 1..<2])
    }

    func testGapBelowEpsilonDoesNotSplit() {
        let cues = [cue(0, 1000, "we shall fight"), cue(1999, 3000, "on the beaches")]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<2])
        XCTAssertEqual(chunks[0].text, "we shall fight on the beaches")
    }

    func testPunctuationFreeGapOnlyChunking() {
        let cues = [
            cue(0, 900, "we shall fight"),
            cue(950, 1800, "on the beaches"),
            cue(2900, 3600, "we shall never"),
            cue(3700, 4400, "surrender"),
        ]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<2, 2..<4])
        XCTAssertEqual(chunks[0].text, "we shall fight on the beaches")
        XCTAssertEqual(chunks[1].text, "we shall never surrender")
    }

    // MARK: - Chunking: sentence terminators

    func testSentenceTerminalCharactersEndChunks() {
        for terminator in [".", "!", "?", "…", "。", "！", "？", "۔", "؟", "।"] {
            let cues = [cue(0, 1000, "hello" + terminator), cue(1100, 2000, "world")]
            let chunks = CaptionChunking.chunk(cues: cues)
            XCTAssertEqual(chunks.count, 2, "terminator \(terminator) must end the chunk")
            XCTAssertEqual(chunks[0].text, "hello" + terminator)
            XCTAssertEqual(chunks[1].text, "world")
        }
    }

    func testNonTerminalPunctuationDoesNotSplit() {
        for nonTerminator in [",", ":", ";", "-"] {
            let cues = [cue(0, 1000, "hello" + nonTerminator), cue(1100, 2000, "world")]
            let chunks = CaptionChunking.chunk(cues: cues)
            XCTAssertEqual(chunks.count, 1, "\(nonTerminator) must not end the chunk")
        }
    }

    // MARK: - Chunking: hard caps

    func testHardCapTwentyCues() {
        let cues = (0..<25).map { cue($0 * 100, $0 * 100 + 90, "word\($0)") }
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<20, 20..<25])
    }

    func testHardCapSixHundredChars() {
        let text = String(repeating: "a", count: 250)
        let cues = [cue(0, 900, text), cue(1000, 1900, text), cue(2000, 2900, text)]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<2, 2..<3])
        XCTAssertEqual(chunks[0].text.count, 501)
    }

    func testOversizeSingleCueStaysWholeChunk() {
        let big = String(repeating: "b", count: 700)
        let cues = [cue(0, 900, "small text"), cue(1000, 1900, big)]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<1, 1..<2])
        XCTAssertEqual(chunks[1].text, big)
    }

    // MARK: - Chunking: run boundaries and overlaps

    func testRunBoundariesNeverSpanned() {
        let cues = [
            cue(0, 900, "end of one"),
            cue(950, 1800, "rolling run"),
            cue(1850, 2700, "start of the"),
            cue(2750, 3600, "next run"),
        ]
        let chunks = CaptionChunking.chunk(cues: cues, runBoundaries: [2])
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<2, 2..<4])
    }

    func testOverlappingCuesAreSoloChunks() {
        let cues = [
            cue(0, 1000, "first speaker"),
            cue(900, 2000, "second speaker"),
            cue(1900, 3000, "third speaker"),
            cue(3050, 4000, "back to normal"),
        ]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<1, 1..<2, 2..<3, 3..<4])
    }

    // MARK: - Chunking: text assembly

    func testSpeakerPrefixStrippedFromChunkText() {
        let cues = [
            Cue(
                startMs: 0, endMs: 1000,
                lines: [
                    CueLine(text: "Bob: hello there", hadInlineTimestamps: false, speakerPrefix: "Bob: ")
                ]),
            cue(1100, 2000, "general kenobi"),
        ]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "hello there general kenobi")
    }

    func testMultiLineCueJoinedWithSingleSpaces() {
        let cues = [
            Cue(
                startMs: 0, endMs: 1000,
                lines: [
                    CueLine(text: "first line", hadInlineTimestamps: false),
                    CueLine(text: " ", hadInlineTimestamps: false),
                    CueLine(text: "second line", hadInlineTimestamps: true),
                ])
        ]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks[0].text, "first line second line")
        XCTAssertFalse(chunks[0].text.contains("\n"))
    }

    // MARK: - Redistribution: the spec's worked example

    // Source grapheme lengths [12, 5, 23] -> cumulative offsets at 12/40 and
    // 17/40 of the 40-grapheme target -> raw positions 12 and 17 land inside
    // "brown" and "fox" and snap to the nearest earlier word boundaries.
    func testWorkedExampleRedistribution() {
        let cues = [
            cue(0, 2000, "twelve chars"),
            cue(2100, 3000, "hello"),
            cue(3100, 5000, "abcdefghij klmnopqrstuv"),
        ]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<3])

        let result = CaptionChunking.redistribute(
            translatedText: "The quick brown fox jumps over lazy dogs",
            into: chunks[0],
            cues: cues,
            targetLanguage: english
        )
        XCTAssertFalse(result.usedSourceFallback)
        XCTAssertEqual(
            result.cues.map { $0.lines[0].text },
            ["The quick", "brown", "fox jumps over lazy dogs"]
        )
        // Text only: timings identical to the source cues.
        XCTAssertEqual(result.cues.map(\.startMs), [0, 2100, 3100])
        XCTAssertEqual(result.cues.map(\.endMs), [2000, 3000, 5000])
        for output in result.cues {
            let text = output.lines[0].text
            XCTAssertEqual(text, text.trimmingCharacters(in: .whitespaces), "no mid-word or padded edges")
        }
    }

    // MARK: - Redistribution: spaceless target script

    // Weights [1, 2] over a 12-grapheme Japanese string put the raw offset at
    // 4, inside the token 日本語 — it must snap (tie toward earlier) to 3.
    func testRedistributionSnapsToWordBoundariesInSpacelessScript() {
        let cues = [cue(0, 1000, "a"), cue(1100, 2000, "bc")]
        let result = CaptionChunking.redistribute(
            translatedText: "これは日本語のテストです",
            into: CaptionChunk(cueIndices: 0..<2, text: "a bc"),
            cues: cues,
            targetLanguage: Locale.Language(identifier: "ja")
        )
        XCTAssertFalse(result.usedSourceFallback)
        XCTAssertEqual(result.cues.map { $0.lines[0].text }, ["これは", "日本語のテストです"])
    }

    // MARK: - Redistribution: empty-cue fold-forward

    func testShrinkingTranslationFoldsEmptyCueForward() {
        let cues = [
            cue(0, 1000, "aaaaaaaaaa"),
            cue(1100, 2000, "bbbbbbbbbb"),
            cue(2100, 3000, "cccccccccc"),
        ]
        let result = CaptionChunking.redistribute(
            translatedText: "Yes okay",
            into: CaptionChunk(cueIndices: 0..<3, text: "aaaaaaaaaa bbbbbbbbbb cccccccccc"),
            cues: cues,
            targetLanguage: english
        )
        XCTAssertFalse(result.usedSourceFallback)
        XCTAssertEqual(result.cues.map { $0.lines[0].text }, ["Yes", "okay"])
        // The dropped middle cue's range folds into the previous survivor.
        XCTAssertEqual(result.cues.map(\.startMs), [0, 2100])
        XCTAssertEqual(result.cues.map(\.endMs), [2000, 3000])
    }

    func testZeroWeightCueDroppedAndFoldedForward() {
        let cues = [
            cue(0, 1000, "aaaaa"),
            cue(1100, 1200, " "),
            cue(1300, 2000, "bbbbb"),
        ]
        let chunks = CaptionChunking.chunk(cues: cues)
        XCTAssertEqual(chunks.map(\.cueIndices), [0..<3])
        XCTAssertEqual(chunks[0].text, "aaaaa bbbbb")

        let result = CaptionChunking.redistribute(
            translatedText: "bonjour monde",
            into: chunks[0],
            cues: cues,
            targetLanguage: Locale.Language(identifier: "fr")
        )
        XCTAssertFalse(result.usedSourceFallback)
        XCTAssertEqual(result.cues.map { $0.lines[0].text }, ["bonjour", "monde"])
        XCTAssertEqual(result.cues.map(\.startMs), [0, 1300])
        XCTAssertEqual(result.cues.map(\.endMs), [1200, 2000])
    }

    // MARK: - Redistribution: identity, fallback, prefixes, weights

    func testSingleCueChunkIdentity() {
        let cues = [cue(500, 1500, "hola")]
        let result = CaptionChunking.redistribute(
            translatedText: "hello",
            into: CaptionChunk(cueIndices: 0..<1, text: "hola"),
            cues: cues,
            targetLanguage: english
        )
        XCTAssertFalse(result.usedSourceFallback)
        XCTAssertEqual(result.cues.count, 1)
        XCTAssertEqual(result.cues[0].lines[0].text, "hello")
        XCTAssertEqual(result.cues[0].startMs, 500)
        XCTAssertEqual(result.cues[0].endMs, 1500)
    }

    func testAllEmptyTranslationFallsBackToSourceText() {
        let cues = [cue(0, 1000, "foo"), cue(1100, 2000, "bar")]
        let result = CaptionChunking.redistribute(
            translatedText: "  \u{200B}",
            into: CaptionChunk(cueIndices: 0..<2, text: "foo bar"),
            cues: cues,
            targetLanguage: english
        )
        XCTAssertTrue(result.usedSourceFallback)
        XCTAssertEqual(result.cues.map { $0.lines[0].text }, ["foo", "bar"])
        XCTAssertEqual(result.cues.map(\.startMs), [0, 1100])
        XCTAssertEqual(result.cues.map(\.endMs), [1000, 2000])
    }

    func testSpeakerPrefixReattachedVerbatim() {
        let cues = [
            Cue(
                startMs: 0, endMs: 1000,
                lines: [CueLine(text: "Bob: hi there", hadInlineTimestamps: false, speakerPrefix: "Bob: ")]),
            cue(1100, 2000, "friend"),
        ]
        let result = CaptionChunking.redistribute(
            translatedText: "salut mon ami",
            into: CaptionChunk(cueIndices: 0..<2, text: "hi there friend"),
            cues: cues,
            targetLanguage: Locale.Language(identifier: "fr")
        )
        XCTAssertFalse(result.usedSourceFallback)
        XCTAssertEqual(result.cues.map { $0.lines[0].text }, ["Bob: salut", "mon ami"])
        XCTAssertEqual(result.cues[0].lines[0].speakerPrefix, "Bob: ")
        XCTAssertNil(result.cues[1].lines[0].speakerPrefix)
    }

    // Weights count grapheme clusters excluding Cf format characters: a cue of
    // "a" + three LRMs weighs 1, not 4. With Cf excluded the split lands after
    // "no"; counted, it would land after "way".
    func testWeightsExcludeFormatCharacters() {
        let cues = [cue(0, 1000, "a\u{200E}\u{200E}\u{200E}"), cue(1100, 2000, "bcd")]
        let result = CaptionChunking.redistribute(
            translatedText: "no way yes sir",
            into: CaptionChunk(cueIndices: 0..<2, text: "a\u{200E}\u{200E}\u{200E} bcd"),
            cues: cues,
            targetLanguage: english
        )
        XCTAssertEqual(result.cues.map { $0.lines[0].text }, ["no", "way yes sir"])
    }
}
