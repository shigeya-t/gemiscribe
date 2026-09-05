import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(Localizer.self) private var loc

    @State private var isClearConfirmationPresented = false

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            header
            Divider()
            ControlBarView()
            if let message = appState.errorMessage {
                errorBanner(message)
            }
            Divider()
            TranscriptListView()
            Divider()
            footer
        }
        .sheet(isPresented: $state.isSettingsPresented) {
            SettingsView()
                .environment(appState)
                .environment(loc)
        }
        .confirmationDialog(loc[.clearConfirmTitle],
                            isPresented: $isClearConfirmationPresented) {
            Button(loc[.delete], role: .destructive) { appState.clearTranscript() }
            Button(loc[.cancel], role: .cancel) {}
        } message: {
            Text(loc[.clearConfirmMessage])
        }
    }

    // MARK: - Header

    private var header: some View {
        @Bindable var localizer = loc

        return HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.tint)
            Text(loc[.appTitle]).font(.headline)

            Spacer()

            Picker(loc[.uiLanguage], selection: $localizer.language) {
                ForEach(AppLanguage.allCases) { language in
                    // Each option is written in its own language so it stays
                    // recognisable whichever one is currently active.
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Button {
                appState.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(loc[.settings])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if appState.errorOffersPrivacyShortcut {
                Button(loc[.openPrivacySettings]) { appState.openPrivacySettings() }
                    .controlSize(.small)
            }
            Button(loc[.dismiss]) { appState.errorMessage = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(loc.format(.blockCountFormat,
                            appState.transcript.blocks.count,
                            TimecodeFormatter.string(from: appState.transcript.durationSec)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button(loc[.clear]) { isClearConfirmationPresented = true }
                .disabled(appState.transcript.isEmpty || appState.isRecording)

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(loc[format.locKey]) { appState.save(format: format) }
                }
            } label: {
                Label(loc[.save], systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(appState.transcript.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
