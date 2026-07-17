import SwiftUI

struct RootView: View {
    @State private var whisperReady = WhisperEngine.whisperPath != nil
    @State private var ffmpegReady = WhisperEngine.ffmpegPath != nil
    @State private var modelReady = WhisperEngine.modelIsReady

    var isReady: Bool { whisperReady && ffmpegReady && modelReady }

    var body: some View {
        Group {
            if isReady {
                ContentView()
            } else {
                SetupView(
                    whisperReady: $whisperReady,
                    ffmpegReady: $ffmpegReady,
                    modelReady: $modelReady,
                    recheck: recheck
                )
            }
        }
        // Kept mounted for the app's whole lifetime: TranslationSession
        // only exists while a view hosting .translationTask is alive.
        .background(TranslationBridgeView(bridge: TranslationBridge.shared))
    }

    func recheck() {
        whisperReady = WhisperEngine.whisperPath != nil
        ffmpegReady = WhisperEngine.ffmpegPath != nil
        modelReady = WhisperEngine.modelIsReady
    }
}
