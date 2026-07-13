import AppKit
import SwiftUI

struct JobRowView: View {
    let job: TranscriptionJob
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.filename)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusDetail
                }
                Spacer()
                if !job.transcript.isEmpty {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded, !job.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button(copied ? "Copied" : "Copy Transcript") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.transcript, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        }
                        if job.status == .done {
                            Button("Reveal .txt in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
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
        .contentShape(Rectangle())
        .onTapGesture {
            if !job.transcript.isEmpty {
                withAnimation { expanded.toggle() }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .converting, .transcribing:
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
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .done:
            Text("Saved \(job.outputURL.lastPathComponent)")
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text(job.status.label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
