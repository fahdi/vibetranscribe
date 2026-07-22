import Foundation

/// Script-detection helper backing the Devanagari guard: Whisper's
/// auto-detect occasionally mistakes spoken Urdu for Hindi and transliterates
/// the output into Devanagari script instead of the expected Perso-Arabic
/// script. When that happens for an "auto" + non-translate chunk, callers
/// re-run the same audio once with language forced to "ur".
enum TextScript {
    /// Devanagari Unicode block (U+0900–U+097F) — covers Hindi, Marathi, and
    /// related scripts. Urdu uses the Arabic block instead, so a majority of
    /// "letter" characters landing in this range signals a misdetection.
    private static let devanagariRange: ClosedRange<UInt32> = 0x0900...0x097F

    /// True when more than 40% of the letter characters in `s` fall inside
    /// the Devanagari block. Non-letter characters (spaces, punctuation,
    /// digits) are ignored so they don't dilute the ratio.
    static func isMajorityDevanagari(_ s: String) -> Bool {
        var letterCount = 0
        var devanagariCount = 0
        for scalar in s.unicodeScalars where scalar.properties.isAlphabetic {
            letterCount += 1
            if devanagariRange.contains(scalar.value) {
                devanagariCount += 1
            }
        }
        guard letterCount > 0 else { return false }
        return Double(devanagariCount) / Double(letterCount) > 0.4
    }
}
