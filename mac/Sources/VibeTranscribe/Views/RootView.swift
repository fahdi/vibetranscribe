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
    }

    func recheck() {
        whisperReady = WhisperEngine.whisperPath != nil
        ffmpegReady = WhisperEngine.ffmpegPath != nil
        modelReady = WhisperEngine.modelIsReady
    }
}
