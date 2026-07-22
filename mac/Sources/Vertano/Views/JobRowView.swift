import AppKit
import SwiftUI

struct JobRowView: View {
    let job: Job
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expand/collapse tap lives on the header only, so selecting text
            // in the transcript below never collapses the row.
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.filename)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusDetail
                    if case .captions(let caption) = job,
                        let code = caption.sourceLanguageCode
                    {
                        Text("Source language: \(CaptionPipeline.displayName(code))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !job.displayText.isEmpty {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !job.displayText.isEmpty {
                    withAnimation { expanded.toggle() }
                }
            }
            if expanded, !job.displayText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.displayText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button(copied ? "Copied" : "Copy Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.displayText, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        }
                        // doneWithWarning is the COMMON caption success
                        // outcome (skipped/unsupported language notes with
                        // every file saved), so Reveal shows for it too.
                        if showsReveal {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [job.primaryOutputURL])
                            }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var showsReveal: Bool {
        switch job.status {
        case .done, .doneWithWarning: return true
        default: return false
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .converting, .transcribing, .translating:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .doneWithWarning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch job.status {
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        case .doneWithWarning(let message):
            Text("\(job.status.label(for: job.kind)): \(message)")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .done:
            Text("Saved \(job.primaryOutputURL.lastPathComponent)")
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text(job.status.label(for: job.kind)).font(.caption).foregroundStyle(.secondary)
        }
    }
}
