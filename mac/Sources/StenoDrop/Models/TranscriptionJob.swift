import Foundation

enum JobStatus: Equatable {
    case queued
    case converting
    case transcribing
    case done
    case doneWithWarning(String)
    case failed(String)

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .converting: return "Converting"
        case .transcribing: return "Transcribing"
        case .done: return "Done"
        case .doneWithWarning: return "Done (not saved)"
        case .failed: return "Failed"
        }
    }

    var isActive: Bool {
        self == .converting || self == .transcribing
    }

    var isFinished: Bool {
        switch self {
        case .done, .doneWithWarning, .failed: return true
        default: return false
        }
    }
}

struct TranscriptionJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    /// Assigned at enqueue time so same-basename sources (a.mp3 + a.wav)
    /// never silently clobber each other's transcript.
    let outputURL: URL
    var status: JobStatus = .queued
    var transcript: String = ""

    var filename: String { sourceURL.lastPathComponent }

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
