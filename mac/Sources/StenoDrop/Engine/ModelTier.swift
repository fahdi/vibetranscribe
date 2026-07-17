import Foundation

/// A whisper.cpp model choice, framed to users by capability rather than
/// by filename or size.
enum ModelTier: String, CaseIterable, Codable, Identifiable {
    case efficient
    case enhanced
    case maximum

    var id: String { rawValue }

    static let `default`: ModelTier = .efficient

    var filename: String {
        switch self {
        case .efficient: "ggml-small.bin"
        case .enhanced: "ggml-medium.bin"
        case .maximum: "ggml-large-v3-turbo.bin"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    var title: String {
        switch self {
        case .efficient: "Efficient"
        case .enhanced: "Enhanced"
        case .maximum: "Maximum"
        }
    }

    var summary: String {
        switch self {
        case .efficient: "Fast and lightweight. Great for single-language recordings."
        case .enhanced: "Sharper accuracy — handles accents, mixed audio, and background noise better."
        case .maximum: "Our most capable model. Built for multilingual and Indic-language audio, including code-switching."
        }
    }

    /// Approximate download size shown alongside the capability copy —
    /// informational only, never the lead of the sales pitch.
    var approximateSizeLabel: String {
        switch self {
        case .efficient: "~500 MB"
        case .enhanced: "~1.5 GB"
        case .maximum: "~1.6 GB"
        }
    }

    /// Anything under this is a truncated download or an error page, even
    /// if the HTTP layer called it a success. Scaled per tier since the
    /// models range from ~500 MB to ~1.6 GB.
    var minimumValidSize: Int64 {
        switch self {
        case .efficient: 400_000_000
        case .enhanced: 1_300_000_000
        case .maximum: 1_400_000_000
        }
    }
}
