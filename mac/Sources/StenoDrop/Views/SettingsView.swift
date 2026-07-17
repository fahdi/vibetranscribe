import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelTierSettingsView()
                .tabItem { Label("Model", systemImage: "cpu") }
            TranslationSettingsView()
                .tabItem { Label("Translation", systemImage: "globe") }
        }
        .frame(width: 460, height: 360)
        .padding(20)
    }
}

private struct ModelTierSettingsView: View {
    @EnvironmentObject var queue: JobQueue
    @StateObject private var downloader = ModelDownloader()
    @State private var activeTier = WhisperEngine.activeTier
    @State private var readyTiers: Set<ModelTier> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the model used for transcription. Bigger models handle accents, mixed audio, and Indic-language code-switching better — at the cost of a larger download.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(ModelTier.allCases) { tier in
                    tierRow(tier)
                    if tier != ModelTier.allCases.last { Divider() }
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            Spacer()
        }
        .onAppear(perform: refreshReadyTiers)
        .onChange(of: downloader.isDownloading) { _, downloading in
            if !downloading { refreshReadyTiers() }
        }
    }

    private func tierRow(_ tier: ModelTier) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activeTier == tier ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(activeTier == tier ? Color.accentColor : Color.secondary)
                .font(.title3)
                .onTapGesture {
                    guard readyTiers.contains(tier) else { return }
                    activeTier = tier
                    WhisperEngine.activeTier = tier
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tier.title).fontWeight(.medium)
                    Text(tier.approximateSizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(tier.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if readyTiers.contains(tier) {
                    if activeTier != tier {
                        Button("Use This Model") {
                            activeTier = tier
                            WhisperEngine.activeTier = tier
                        }
                        .controlSize(.small)
                    }
                } else if downloader.isDownloading, downloader.downloadingTier == tier {
                    ProgressView(value: downloader.progress)
                        .frame(maxWidth: 200)
                } else {
                    Button("Download") { downloader.start(tier: tier) }
                        .controlSize(.small)
                        .disabled(downloader.isDownloading)
                    if downloader.downloadingTier == nil, let error = downloader.error {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private func refreshReadyTiers() {
        readyTiers = Set(ModelTier.allCases.filter { WhisperEngine.modelIsReady(for: $0) })
    }
}

private struct TranslationSettingsView: View {
    @EnvironmentObject var queue: JobQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The original spoken-language transcript is always saved. Check additional languages to also save a translated copy of each transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(JobQueue.languages.filter { $0.code != "auto" }, id: \.code) { language in
                        Toggle(
                            language.name,
                            isOn: Binding(
                                get: { queue.targetLanguages.contains(language.code) },
                                set: { isOn in
                                    if isOn {
                                        queue.targetLanguages.insert(language.code)
                                    } else {
                                        queue.targetLanguages.remove(language.code)
                                    }
                                }
                            ))
                    }
                }
                .padding(.vertical, 4)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
