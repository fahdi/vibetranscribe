import Foundation
import NaturalLanguage

/// One translator input string covering a contiguous range of reflowed cues.
/// `text` is the cues' cleaned texts joined with single spaces — speaker
/// prefixes stripped (re-attached after redistribution), no internal newlines.
struct CaptionChunk: Sendable, Equatable {
    let cueIndices: Range<Int>
    let text: String
}

/// `usedSourceFallback` signals a chunk whose entire translation came back
/// empty: the cues carry cleaned source text and the caller must attach the
/// `doneWithWarning` note.
struct RedistributionResult: Sendable, Equatable {
    let cues: [Cue]
    let usedSourceFallback: Bool
}

/// Pure sentence chunking + proportional redistribution (spec §5). Per-cue
/// translation of 3-8 word rolling fragments yields word salad, so cues are
/// merged into sentence-ish chunks for the translator and the translated
/// string is split back across the member cues by source-length proportion.
enum CaptionChunking {

    /// Reflow's ε, shared per spec (§5 uses "the same constant as §2"): a gap
    /// this large is an unconditional chunk boundary because auto-captions
    /// are largely punctuation-free — without it a lecture degenerates into
    /// one giant chunk.
    private static let epsilonMs = CaptionReflow.epsilonMs
    private static let maxChunkCharacters = 600
    private static let maxChunkCues = 20

    // MARK: - Chunking

    /// `runBoundaries` holds indices of cues that START a new reflow run; a
    /// chunk never spans one (chunk boundaries are a strict superset of run
    /// boundaries). Cues that time-overlap a neighbor are always solo chunks.
    static func chunk(cues: [Cue], runBoundaries: Set<Int> = []) -> [CaptionChunk] {
        var chunks: [CaptionChunk] = []
        var chunkStart = 0
        var chunkText = ""
        var previousCueText = ""

        func close(before index: Int) {
            guard index > chunkStart else { return }
            chunks.append(CaptionChunk(cueIndices: chunkStart..<index, text: chunkText))
            chunkStart = index
            chunkText = ""
        }

        for index in cues.indices {
            let cueText = cleanedText(of: cues[index])
            if index > 0 {
                var boundary =
                    runBoundaries.contains(index)
                    || cues[index].startMs - cues[index - 1].endMs >= epsilonMs
                    || endsAtSentenceBoundary(previousCueText)
                    || overlapsNeighbor(cues, at: index)
                    || overlapsNeighbor(cues, at: index - 1)
                if !boundary, index - chunkStart >= maxChunkCues {
                    boundary = true
                }
                if !boundary, !chunkText.isEmpty, !cueText.isEmpty,
                    chunkText.count + 1 + cueText.count > maxChunkCharacters
                {
                    boundary = true
                }
                if boundary { close(before: index) }
            }
            if !cueText.isEmpty {
                chunkText = chunkText.isEmpty ? cueText : chunkText + " " + cueText
            }
            previousCueText = cueText
        }
        close(before: cues.count)
        return chunks
    }

    /// A cue's translator-facing text: speaker prefixes stripped, effectively
    /// empty lines dropped, remaining lines joined with single spaces.
    private static func cleanedText(of cue: Cue) -> String {
        cue.lines
            .map { line in
                var text = line.text
                if let prefix = line.speakerPrefix, text.hasPrefix(prefix) {
                    text.removeFirst(prefix.count)
                }
                return trimEdges(text)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// U+2026 is spec-mandated as a boundary but has Sentence_Terminal=No in
    /// the UCD, so it rides alongside the property check.
    private static func endsAtSentenceBoundary(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return last.properties.isSentenceTerminal || last == "\u{2026}"
    }

    private static func overlapsNeighbor(_ cues: [Cue], at index: Int) -> Bool {
        if index > 0, cues[index - 1].endMs > cues[index].startMs { return true }
        if index + 1 < cues.count, cues[index].endMs > cues[index + 1].startMs { return true }
        return false
    }

    // MARK: - Redistribution

    /// Splits `translatedText` back across the chunk's member cues in
    /// proportion to their source grapheme weights, snapping each split to a
    /// target-language word boundary. Assigns text only — surviving cues keep
    /// their source timings, except fold-forward `endMs` extension over
    /// dropped empty cues.
    static func redistribute(
        translatedText: String,
        into chunk: CaptionChunk,
        cues: [Cue],
        targetLanguage: Locale.Language?
    ) -> RedistributionResult {
        let members = Array(cues[chunk.cueIndices])
        let cleanedTexts = members.map(cleanedText(of:))
        let weights = cleanedTexts.map(graphemeWeight(of:))
        let translated = trimEdges(translatedText)

        guard !translated.isEmpty, weights.reduce(0, +) > 0 else {
            return sourceFallback(members: members, cleanedTexts: cleanedTexts)
        }

        let target = Array(translated)
        let counts = apportion(total: target.count, weights: weights)
        let boundaries = wordBoundarySplitPositions(in: translated, language: targetLanguage)

        var offsets: [Int] = []
        var cumulative = 0
        for count in counts.dropLast() {
            cumulative += count
            let snapped = snap(cumulative, to: boundaries)
            offsets.append(max(snapped, offsets.last ?? 0))
        }
        offsets.append(target.count)

        var output: [Cue] = []
        var segmentStart = 0
        for (member, offset) in zip(members, offsets) {
            let segment = trimEdges(String(target[segmentStart..<offset]))
            segmentStart = offset
            if segment.isEmpty {
                // Fold-forward: the previous survivor absorbs the dropped
                // cue's range; a leading empty cue has nowhere to fold and is
                // discarded outright.
                if let previous = output.last {
                    output[output.count - 1] = Cue(
                        startMs: previous.startMs,
                        endMs: max(previous.startMs, max(previous.endMs, member.endMs)),
                        lines: previous.lines
                    )
                }
                continue
            }
            output.append(translatedCue(for: member, text: segment))
        }

        guard !output.isEmpty else {
            return sourceFallback(members: members, cleanedTexts: cleanedTexts)
        }
        return RedistributionResult(cues: output, usedSourceFallback: false)
    }

    private static func translatedCue(for member: Cue, text: String) -> Cue {
        let prefix = member.lines.compactMap(\.speakerPrefix).first
        return Cue(
            startMs: member.startMs,
            endMs: member.endMs,
            lines: [
                CueLine(
                    text: (prefix ?? "") + text,
                    hadInlineTimestamps: false,
                    speakerPrefix: prefix
                )
            ]
        )
    }

    private static func sourceFallback(members: [Cue], cleanedTexts: [String]) -> RedistributionResult {
        let cues = zip(members, cleanedTexts).map { member, text in
            translatedCue(for: member, text: text)
        }
        return RedistributionResult(cues: cues, usedSourceFallback: true)
    }

    // MARK: - Weights and apportionment

    /// Grapheme clusters excluding characters that are purely Cf (format) —
    /// directional marks must not skew the proportions.
    private static func graphemeWeight(of text: String) -> Int {
        text.count(where: { character in
            !character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
        })
    }

    /// Largest-remainder apportionment of `total` target graphemes across the
    /// weights; remainder ties break toward the earlier cue.
    private static func apportion(total: Int, weights: [Int]) -> [Int] {
        let weightSum = weights.reduce(0, +)
        var counts = weights.map { $0 * total / weightSum }
        var leftover = total - counts.reduce(0, +)
        let byRemainder = weights.indices.sorted {
            let left = weights[$0] * total % weightSum
            let right = weights[$1] * total % weightSum
            return left != right ? left > right : $0 < $1
        }
        for index in byRemainder where leftover > 0 {
            counts[index] += 1
            leftover -= 1
        }
        return counts
    }

    // MARK: - Word-boundary snapping

    /// Grapheme-offset ranges of word tokens; any position strictly inside one
    /// is not a legal split point. NLTokenizer is configured for the TARGET
    /// language so spaceless scripts (ja/zh/ko/th) segment correctly.
    private static func wordBoundarySplitPositions(
        in text: String,
        language: Locale.Language?
    ) -> [(start: Int, end: Int)] {
        let tokenizer = NLTokenizer(unit: .word)
        if let code = language?.languageCode?.identifier {
            tokenizer.setLanguage(NLLanguage(rawValue: code))
        }
        tokenizer.string = text
        var ranges: [(start: Int, end: Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(
                (
                    start: text.distance(from: text.startIndex, to: range.lowerBound),
                    end: text.distance(from: text.startIndex, to: range.upperBound)
                ))
            return true
        }
        return ranges
    }

    /// Positions never index inside a grapheme cluster (they are Character
    /// offsets); this only moves ones that fall inside a word token, to the
    /// nearest token edge, ties toward the earlier one.
    private static func snap(_ position: Int, to tokens: [(start: Int, end: Int)]) -> Int {
        for token in tokens where token.start < position && position < token.end {
            return position - token.start <= token.end - position ? token.start : token.end
        }
        return position
    }

    /// Edge trim used everywhere a segment or line becomes cue text: strips
    /// whitespace (including U+00A0) and zero-width Cf characters, mirroring
    /// `CaptionFile.isEffectivelyEmpty`.
    private static func trimEdges(_ text: String) -> String {
        func isTrimmable(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy {
                $0.properties.isWhitespace || $0.properties.generalCategory == .format
            }
        }
        var result = Substring(text)
        while let first = result.first, isTrimmable(first) { result.removeFirst() }
        while let last = result.last, isTrimmable(last) { result.removeLast() }
        return String(result)
    }
}
