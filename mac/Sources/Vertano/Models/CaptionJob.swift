import Foundation

/// A dropped `.srt`/`.vtt` file: cleaned (rolling-caption reflow) and
/// translated into timed caption tracks. No audio, no whisper — the file
/// already is the transcript.
struct CaptionJob: Identifiable, Sendable {
    let id = UUID()
    let sourceURL: URL
    let format: CaptionFormat
    /// Target-language output URLs, claimed at enqueue (§8 phase one). The
    /// source-track path can't be claimed here — the source language isn't
    /// known until resolution (§3) — so it lands in `sourceTrackURL` later.
    let targetOutputs: [String: URL]
    var status: JobStatus = .queued
    /// Flattened reflowed text for the expanded row view.
    var reflowedText: String = ""
    /// Detected/used source language, shown in the job row.
    var sourceLanguageCode: String?
    /// Claimed at source-resolution time (§8 phase two).
    var sourceTrackURL: URL?
    var sourceTextURL: URL?

    var filename: String { sourceURL.lastPathComponent }

    var prospectiveOutputPaths: Set<String> {
        var paths = Set(targetOutputs.values.map(\.path))
        if let sourceTrackURL { paths.insert(sourceTrackURL.path) }
        if let sourceTextURL { paths.insert(sourceTextURL.path) }
        return paths
    }
}

/// The one heterogeneous queue entry. Cases carry value-type jobs, so every
/// mutation is extract-mutate-reassign — the computed setters below keep the
/// existing `jobs[index].status = ...` call shape working.
enum Job: Identifiable {
    case audio(TranscriptionJob)
    case captions(CaptionJob)

    var id: UUID {
        switch self {
        case .audio(let job): return job.id
        case .captions(let job): return job.id
        }
    }

    var kind: JobKind {
        switch self {
        case .audio: return .audio
        case .captions: return .captions
        }
    }

    var sourceURL: URL {
        switch self {
        case .audio(let job): return job.sourceURL
        case .captions(let job): return job.sourceURL
        }
    }

    var filename: String { sourceURL.lastPathComponent }

    var status: JobStatus {
        get {
            switch self {
            case .audio(let job): return job.status
            case .captions(let job): return job.status
            }
        }
        set {
            switch self {
            case .audio(var job):
                job.status = newValue
                self = .audio(job)
            case .captions(var job):
                job.status = newValue
                self = .captions(job)
            }
        }
    }

    /// What the expanded row shows: the transcript for audio, the cleaned
    /// reflowed text for captions.
    var displayText: String {
        switch self {
        case .audio(let job): return job.transcript
        case .captions(let job): return job.reflowedText
        }
    }

    /// The file Reveal in Finder selects.
    var primaryOutputURL: URL {
        switch self {
        case .audio(let job): return job.outputURL
        case .captions(let job):
            return job.sourceTrackURL ?? job.targetOutputs.values.sorted { $0.path < $1.path }.first
                ?? job.sourceURL
        }
    }

    var prospectiveOutputPaths: Set<String> {
        switch self {
        case .audio(let job): return job.prospectiveOutputPaths
        case .captions(let job): return job.prospectiveOutputPaths
        }
    }
}

/// Deterministic caption output naming (§8): `<stripped base>.<lang>.<ext>`
/// next to the source. Names are app-owned and overwritten on re-run, same
/// as the audio pipeline's `song.txt`.
enum CaptionNaming {

    /// Basename with one recognized trailing language code removed
    /// (`Talk.en` → `Talk`, `Video.en-orig` → `Video`); yt-dlp always writes
    /// `<name>.<lang>.<ext>`, so unstripped comparison matches zero real
    /// folders. `Talk.part2` is left alone.
    static func strippedBaseName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base }
        let token = base[base.index(after: dot)...]
        return isLanguageCodeToken(token) ? String(base[..<dot]) : base
    }

    /// A primary language subtag that ISO 639 recognizes, optionally followed
    /// by 2-8 character alphanumeric subtags (`en`, `zh-Hans`, `en-orig`).
    static func isLanguageCodeToken(_ token: Substring) -> Bool {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first,
            (2...3).contains(first.count),
            first.allSatisfy({ $0.isASCII && $0.isLetter }),
            Locale.LanguageCode(String(first).lowercased()).isISOLanguage
        else { return false }
        for part in parts.dropFirst() {
            guard (2...8).contains(part.count),
                part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { return false }
        }
        return true
    }

    static func outputURL(source: URL, language: String, fileExtension: String) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(strippedBaseName(source))
            .appendingPathExtension(language)
            .appendingPathExtension(fileExtension)
    }

    /// Collision fallback: keep the full source filename as the base, the
    /// same `appendingPathExtension` disambiguation the audio path uses.
    static func fallbackOutputURL(source: URL, language: String, fileExtension: String) -> URL {
        source.appendingPathExtension(language).appendingPathExtension(fileExtension)
    }

    static func containerExtension(_ format: CaptionFormat) -> String {
        format == .srt ? "srt" : "vtt"
    }
}
