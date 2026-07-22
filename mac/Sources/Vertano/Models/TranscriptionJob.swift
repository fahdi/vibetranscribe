import Foundation

/// Which pipeline a job runs through. Several strings differ by kind:
/// "Transcribing" vs cleaning captions, and `doneWithWarning` means
/// "couldn't save" for audio but "finished with notes" for captions.
enum JobKind: Equatable, Sendable {
    case audio
    case captions
}

enum JobStatus: Equatable, Sendable {
    case queued
    case converting
    case transcribing
    case done
    case doneWithWarning(String)
    case failed(String)
    case translating(language: String, current: Int, total: Int)

    func label(for kind: JobKind) -> String {
        switch self {
        case .queued: return "Queued"
        case .converting: return "Converting"
        case .transcribing:
            return kind == .audio ? "Transcribing" : "Cleaning captions"
        case .done: return "Done"
        case .doneWithWarning:
            return kind == .audio ? "Done (not saved)" : "Done with notes"
        case .failed: return "Failed"
        case .translating(let language, let current, let total):
            return "Translating \(language) (\(current)/\(total))"
        }
    }

    /// Exhaustive on purpose: the quit guard (`hasActiveWork`) depends on
    /// every in-flight state being active — an `==` chain would silently
    /// exclude `.translating` and let the app quit mid-batch.
    var isActive: Bool {
        switch self {
        case .converting, .transcribing, .translating: return true
        case .queued, .done, .doneWithWarning, .failed: return false
        }
    }

    var isFinished: Bool {
        switch self {
        case .done, .doneWithWarning, .failed: return true
        case .queued, .converting, .transcribing, .translating: return false
        }
    }
}

struct TranscriptionJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    /// Assigned at enqueue time so same-basename sources (a.mp3 + a.wav)
    /// never silently clobber each other's transcript.
    let outputURL: URL
    /// Captured at enqueue so the prospective output set (and therefore
    /// collision claiming) can't drift if the user edits the translate menu
    /// while this job waits in the queue.
    var targetLanguageCodes: Set<String> = []
    var status: JobStatus = .queued
    var transcript: String = ""

    var filename: String { sourceURL.lastPathComponent }

    /// Every path this job may write — the base transcript plus one file per
    /// target language — so the collision check can union over whole jobs
    /// instead of discovering per-language outputs at write time.
    var prospectiveOutputPaths: Set<String> {
        var paths: Set<String> = [outputURL.path]
        for code in targetLanguageCodes {
            paths.insert(outputURL(forLanguage: code).path)
        }
        return paths
    }

    /// `nil` returns the original-language output path unchanged
    /// (`song.txt`, back-compat with every existing job). A language code
    /// inserts it before the extension (`song.en.txt`), even when
    /// `outputURL` was already disambiguated for a source-basename
    /// collision (`song.mp3.txt` -> `song.mp3.en.txt`).
    func outputURL(forLanguage language: String?) -> URL {
        guard let language else { return outputURL }
        return outputURL.deletingPathExtension()
            .appendingPathExtension(language)
            .appendingPathExtension(outputURL.pathExtension)
    }
}
