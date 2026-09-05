import SwiftUI

struct TranscriptListView: View {
    @Environment(AppState.self) private var appState
    @Environment(Localizer.self) private var loc

    /// Guards against scrolling faster than the animations can settle.
    @State private var lastScrollAt = Date.distantPast

    var body: some View {
        let transcript = appState.transcript

        Group {
            if transcript.isEmpty && transcript.interimText.isEmpty {
                // While recording, "no transcript yet" and "waiting for the first result"
                // look identical, and the second one reads as a broken app.
                if appState.isRecording { waitingState } else { emptyState }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(transcript.blocks.enumerated()), id: \.element.id) { index, block in
                                BlockRowView(block: block)
                                    .background(index.isMultiple(of: 2)
                                                ? Color.clear
                                                : Color.secondary.opacity(0.05))
                                    .id(block.id)
                            }

                            if !transcript.interimText.isEmpty {
                                interimRow(transcript.interimText)
                                    .id(Self.interimAnchor)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: transcript.blocks.count) { _, _ in
                        lastScrollAt = Date()
                        scrollToBottom(proxy, animated: true)
                    }
                    .onChange(of: transcript.interimText) { _, _ in
                        guard Date().timeIntervalSince(lastScrollAt) > 0.2 else { return }
                        lastScrollAt = Date()
                        scrollToBottom(proxy, animated: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let interimAnchor = "interim"

    /// Partials arrive several times a second. Animating a scroll for each one queues
    /// up animations faster than they finish, so interim scrolls are unanimated and
    /// only a finalized block is worth animating to.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let transcript = appState.transcript
        let target: (any Hashable)? = !transcript.interimText.isEmpty
            ? Self.interimAnchor
            : transcript.blocks.last?.id
        guard let target else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(AnyHashable(target), anchor: .bottom)
            }
        } else {
            proxy.scrollTo(AnyHashable(target), anchor: .bottom)
        }
    }

    private func interimRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // A running symbol effect here restarts every time the partial text
            // changes, which is several times a second.
            Image(systemName: "waveform")
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(text)
                .foregroundStyle(.tertiary)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 16)
    }

    private var waitingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(loc[.waitingTitle]).font(.headline).foregroundStyle(.secondary)
            Text(loc[.waitingSubtitle])
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(loc[.emptyTitle]).font(.headline).foregroundStyle(.secondary)
            Text(loc[.emptySubtitle]).font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
