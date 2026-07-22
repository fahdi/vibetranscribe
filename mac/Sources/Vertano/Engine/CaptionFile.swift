import Foundation

/// Caption container format. Timestamp separator and header grammar differ
/// per format; everything else in the block grammar is shared.
enum CaptionFormat: Sendable, Equatable {
    case srt
    case vtt

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "srt": self = .srt
        case "vtt": self = .vtt
        default: return nil
        }
    }
}

/// One payload line of a cue, tag-free and entity-decoded. `text` includes
/// the `speakerPrefix` when one was extracted from a `<v Speaker>` tag, so
/// chunking can strip it before translation and re-attach it verbatim.
struct CueLine: Sendable, Equatable {
    let text: String
    let hadInlineTimestamps: Bool
    let speakerPrefix: String?

    init(text: String, hadInlineTimestamps: Bool, speakerPrefix: String? = nil) {
        self.text = text
        self.hadInlineTimestamps = hadInlineTimestamps
        self.speakerPrefix = speakerPrefix
    }
}

/// Integer milliseconds throughout — comma/dot conversion between SRT and
/// VTT must never accumulate floating-point drift.
struct Cue: Sendable, Equatable {
    let startMs: Int
    let endMs: Int
    let lines: [CueLine]
}

enum CaptionFileError: Error, Equatable {
    /// Zero blocks parsed as cues. Distinct from best-effort skipping so the
    /// job can fail outright instead of writing empty output files.
    case noValidCues
}

/// Pure parser/serializer for `.srt`/`.vtt` — no I/O in the core. Malformed
/// blocks are skipped and counted (best-effort), never fatal unless nothing
/// parses at all.
struct CaptionFile: Sendable {
    let format: CaptionFormat
    let cues: [Cue]
    /// Value of the VTT `Language:` header line, when present. Feeds
    /// source-language resolution priority.
    let language: String?
    let warnings: [String]
    let skippedBlockCount: Int

    // MARK: - Parsing

    static func parse(_ data: Data, format: CaptionFormat) throws -> CaptionFile {
        var warnings: [String] = []
        var text = decode(data, warnings: &warnings)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var blocks = splitBlocks(text)
        var language: String?
        if format == .vtt, let first = blocks.first, isHeaderLine(first[0], keyword: "WEBVTT") {
            for line in first where line.hasPrefix("Language:") {
                let value = line.dropFirst("Language:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { language = value }
            }
            blocks.removeFirst()
        }

        var cues: [Cue] = []
        var skipped = 0
        for block in blocks {
            if format == .vtt, ["NOTE", "STYLE", "REGION"].contains(where: { isHeaderLine(block[0], keyword: $0) }) {
                continue
            }
            if let cue = parseCueBlock(block, format: format) {
                cues.append(cue)
            } else {
                skipped += 1
            }
        }

        guard !cues.isEmpty else { throw CaptionFileError.noValidCues }
        if skipped > 0 {
            warnings.append("Skipped \(skipped) unparseable block\(skipped == 1 ? "" : "s")")
        }
        return CaptionFile(
            format: format,
            cues: cues,
            language: language,
            warnings: warnings,
            skippedBlockCount: skipped
        )
    }

    /// Blank line means a truly empty line: whitespace-only lines are real
    /// cue payload in yt-dlp files (the " " filler line) and must not split.
    private static func splitBlocks(_ text: String) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty {
                if !current.isEmpty { blocks.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func isHeaderLine(_ line: String, keyword: String) -> Bool {
        line == keyword || line.hasPrefix(keyword + " ") || line.hasPrefix(keyword + "\t")
    }

    /// The timing line must be the block's first or second line (the second
    /// when an identifier/index precedes it) — scanning deeper would misread
    /// prose that happens to contain an arrow.
    private static func parseCueBlock(_ block: [String], format: CaptionFormat) -> Cue? {
        for timingIndex in 0..<min(2, block.count) {
            let line = block[timingIndex]
            guard let arrow = line.range(of: "-->") else { continue }
            let startToken = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let afterArrow = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let endToken = String(afterArrow.prefix { !$0.isWhitespace })
            guard
                let startMs = parseTimestamp(startToken, format: format),
                let endMs = parseTimestamp(endToken, format: format)
            else { return nil }
            let lines = block[(timingIndex + 1)...].map(parseLine)
            return Cue(startMs: startMs, endMs: endMs, lines: lines)
        }
        return nil
    }

    // MARK: - Timestamps

    static func parseTimestamp(_ string: String, format: CaptionFormat) -> Int? {
        let separator: Character = format == .srt ? "," : "."
        let wrongSeparator: Character = format == .srt ? "." : ","
        guard !string.contains(wrongSeparator), let sepIndex = string.lastIndex(of: separator) else {
            return nil
        }
        let fraction = string[string.index(after: sepIndex)...]
        guard !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        let components = string[..<sepIndex].split(separator: ":", omittingEmptySubsequences: false)
        let hours: Int, minutes: Int, seconds: Int
        switch components.count {
        case 3:
            guard let h = asciiInt(components[0]), let m = asciiInt(components[1]),
                let s = asciiInt(components[2])
            else { return nil }
            (hours, minutes, seconds) = (h, m, s)
        case 2 where format == .vtt:
            guard let m = asciiInt(components[0]), let s = asciiInt(components[1]) else { return nil }
            (hours, minutes, seconds) = (0, m, s)
        default:
            return nil
        }
        guard minutes < 60, seconds < 60 else { return nil }

        // Rounding, never truncation: fraction digits are a decimal fraction
        // of a second, however many there are.
        let digits = fraction.prefix(9)
        var value = 0, denominator = 1
        for character in digits {
            value = value * 10 + character.wholeNumberValue!
            denominator *= 10
        }
        let ms = (value * 1000 + denominator / 2) / denominator
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + ms
    }

    static func formatTimestamp(_ ms: Int, format: CaptionFormat) -> String {
        let total = max(0, ms)
        let separator = format == .srt ? "," : "."
        return String(
            format: "%02d:%02d:%02d%@%03d",
            total / 3_600_000,
            total / 60_000 % 60,
            total / 1000 % 60,
            separator,
            total % 1000
        )
    }

    private static func asciiInt(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    // MARK: - Line content

    /// Tag spans are deleted byte-for-byte with no separator insertion and no
    /// trimming — yt-dlp splits tags mid-word. Entity decoding runs AFTER tag
    /// stripping so `&lt;c&gt;` in content never becomes a tag.
    private static func parseLine(_ raw: String) -> CueLine {
        var stripped = ""
        var hadInlineTimestamps = false
        var speaker: String?
        var insideRubyAnnotation = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "<",
                let close = raw[raw.index(after: index)...].firstIndex(of: ">")
            {
                let tag = raw[raw.index(after: index)..<close]
                if tag.first?.isNumber == true, tag.contains(":") {
                    hadInlineTimestamps = true
                } else if tag == "rt" || tag.hasPrefix("rt ") || tag.hasPrefix("rt.") {
                    insideRubyAnnotation = true
                } else if tag == "/rt" {
                    insideRubyAnnotation = false
                } else if speaker == nil, tag == "v" || tag.hasPrefix("v ") || tag.hasPrefix("v.") {
                    if let space = tag.firstIndex(of: " ") {
                        let name = tag[tag.index(after: space)...].trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { speaker = decodeEntities(name) }
                    }
                }
                index = raw.index(after: close)
                continue
            }
            if !insideRubyAnnotation { stripped.append(character) }
            index = raw.index(after: index)
        }

        var text = decodeEntities(stripped)
        var speakerPrefix: String?
        if let speaker {
            speakerPrefix = speaker + ": "
            text = speakerPrefix! + text
        }
        return CueLine(text: text, hadInlineTimestamps: hadInlineTimestamps, speakerPrefix: speakerPrefix)
    }

    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var out = ""
        var index = string.startIndex
        while index < string.endIndex {
            if string[index] == "&",
                let semicolon = string[index...].firstIndex(of: ";"),
                string.distance(from: index, to: semicolon) <= 9,
                let decoded = decodeEntityBody(string[string.index(after: index)..<semicolon])
            {
                out.append(decoded)
                index = string.index(after: semicolon)
                continue
            }
            out.append(string[index])
            index = string.index(after: index)
        }
        return out
    }

    private static func decodeEntityBody(_ body: Substring) -> Character? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return "\u{00A0}"
        case "lrm": return "\u{200E}"
        case "rlm": return "\u{200F}"
        default:
            guard body.first == "#" else { return nil }
            let numeric = body.dropFirst()
            let value: UInt32?
            if numeric.first == "x" || numeric.first == "X" {
                value = UInt32(numeric.dropFirst(), radix: 16)
            } else {
                value = UInt32(numeric)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
    }

    /// Shared with reflow: a line counts as empty when, after entity decoding,
    /// every scalar is Unicode whitespace (including U+00A0) or a zero-width
    /// format (Cf) character — the yt-dlp filler lines are `&nbsp;` or " ".
    static func isEffectivelyEmpty(_ text: String) -> Bool {
        decodeEntities(text).unicodeScalars.allSatisfy {
            $0.properties.isWhitespace || $0.properties.generalCategory == .format
        }
    }

    // MARK: - Decode ladder

    private static func decode(_ data: Data, warnings: inout [String]) -> String {
        let bom = [UInt8](data.prefix(3))
        if bom.count >= 2, bom[0] == 0xFF, bom[1] == 0xFE,
            let text = String(data: data, encoding: .utf16LittleEndian)
        {
            return text
        }
        if bom.count >= 2, bom[0] == 0xFE, bom[1] == 0xFF,
            let text = String(data: data, encoding: .utf16BigEndian)
        {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        warnings.append("File was not valid UTF-8 — decoded as Windows-1252")
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Serialization

    /// Output convention: UTF-8, no BOM, LF line endings, trailing newline.
    /// SRT indices regenerated 1..N; VTT re-escapes `&` and `<` in payload.
    static func serialize(cues: [Cue], format: CaptionFormat, language: String? = nil) -> String {
        var blocks: [String] = []
        switch format {
        case .srt:
            for (index, cue) in cues.enumerated() {
                var block = "\(index + 1)\n"
                block += formatTimestamp(cue.startMs, format: .srt)
                block += " --> "
                block += formatTimestamp(cue.endMs, format: .srt)
                for line in cue.lines { block += "\n" + line.text }
                blocks.append(block)
            }
        case .vtt:
            var header = "WEBVTT"
            if let language { header += "\nLanguage: \(language)" }
            blocks.append(header)
            for cue in cues {
                var block = formatTimestamp(cue.startMs, format: .vtt)
                block += " --> "
                block += formatTimestamp(cue.endMs, format: .vtt)
                for line in cue.lines { block += "\n" + escapeForVTT(line.text) }
                blocks.append(block)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func escapeForVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
