import SwiftUI

struct SetupView: View {
    @Binding var whisperReady: Bool
    @Binding var ffmpegReady: Bool
    @Binding var modelReady: Bool
    var recheck: () -> Void

    @StateObject private var downloader = ModelDownloader()

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("VibeTranscribe Setup")
                    .font(.title2.bold())
                Text("Two free tools and one model — everything runs on your Mac.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                requirementRow(
                    ok: whisperReady,
                    title: "whisper-cpp",
                    detail: "brew install whisper-cpp"
                )
                requirementRow(
                    ok: ffmpegReady,
                    title: "ffmpeg",
                    detail: "brew install ffmpeg"
                )
                modelRow
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Button("Check Again", action: recheck)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: downloader.isDownloading) { _, downloading in
            if !downloading { recheck() }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(ok: modelReady)
            VStack(alignment: .leading, spacing: 6) {
                Text("Whisper model (small, ~466 MB)")
                    .fontWeight(.medium)
                if modelReady {
                    Text("Downloaded").font(.caption).foregroundStyle(.secondary)
                } else if downloader.isDownloading {
                    ProgressView(value: downloader.progress)
                        .frame(maxWidth: 220)
                    Text("\(Int(downloader.progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Download Model") { downloader.start() }
                    if let error = downloader.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func requirementRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(ok: ok)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                if !ok {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Installed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusIcon(ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .font(.title3)
    }
}
