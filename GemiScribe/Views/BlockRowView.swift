import SwiftUI

struct BlockRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(Localizer.self) private var loc

    let block: TranscriptBlock

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(block.timecode)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(block.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                translationView
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 16)
        .contextMenu {
            Button(loc[.copyText]) { appState.copy(block.text) }
            if let translation = block.translation {
                Button(loc[.copyBoth]) { appState.copy("\(block.text)\n\(translation)") }
            }
            Divider()
            Button(loc[.retranslate]) { appState.translate(block.id, force: true) }
                .disabled(!appState.settings.translationEnabled)
        }
    }

    @ViewBuilder
    private var translationView: some View {
        switch block.translationState {
        case .notRequested:
            EmptyView()
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(loc[.translating]).font(.callout).foregroundStyle(.tertiary)
            }
        case .done:
            if let translation = block.translation {
                Text(translation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(loc[.translationFailed])
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button(loc[.retranslate]) { appState.translate(block.id) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                // Shown in full rather than hidden in a tooltip: the API's own message
                // ("model not found", "quota exceeded") is what actually diagnoses this.
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
