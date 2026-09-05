import SwiftUI

struct ControlBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(Localizer.self) private var loc

    var body: some View {
        @Bindable var settings = appState.settings

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button(action: appState.toggleRecording) {
                    Label(appState.isRecording ? loc[.stopRecording] : loc[.startRecording],
                          systemImage: appState.isRecording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 108)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isRecording ? .red : .accentColor)
                .keyboardShortcut("r", modifiers: .command)

                Text(TimecodeFormatter.string(from: appState.elapsedSec))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(appState.isRecording ? .primary : .secondary)

                Spacer(minLength: 8)

                LevelMeterView(label: loc[.sourceSystemAudio],
                               source: .system,
                               levels: appState.levels,
                               isActive: appState.isRecording && settings.captureSystemAudio)
                LevelMeterView(label: loc[.sourceMicrophone],
                               source: .microphone,
                               levels: appState.levels,
                               isActive: appState.isRecording && settings.captureMicrophone)

                StatusPill(state: appState.status, label: appState.statusLabel)
            }

            HStack(alignment: .center, spacing: 20) {
                Toggle(loc[.sourceSystemAudio], isOn: $settings.captureSystemAudio)
                    .toggleStyle(.switch)
                    .onChange(of: settings.captureSystemAudio) { _, _ in
                        appState.applySourceChange()
                    }
                Toggle(loc[.sourceMicrophone], isOn: $settings.captureMicrophone)
                    .toggleStyle(.switch)
                    .onChange(of: settings.captureMicrophone) { _, _ in
                        appState.applySourceChange()
                    }
                // Smart Transcribe is fixed in the Live API setup message, so it can
                // only change between sessions.
                Toggle(loc[.smartTranscribe], isOn: $settings.smartTranscribe)
                    .toggleStyle(.switch)
                    .help(loc[.smartTranscribeHelp])
                    .disabled(appState.isRecording)
                Spacer()
            }

            HStack(alignment: .center, spacing: 20) {
                // Recognition comes first: it is decided before recording starts,
                // while translation can be toggled at any time.
                Picker(loc[.sourceLanguage], selection: $settings.sourceLanguage) {
                    ForEach(SourceLanguage.allCases) { language in
                        Text(loc.name(of: language)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                // The language is part of the Live API setup message, so it can only
                // change between recordings.
                .disabled(appState.isRecording)
                .help(loc[.sourceLanguageHelp])

                Divider().frame(height: 18)

                Toggle(loc[.translate], isOn: $settings.translationEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: settings.translationEnabled) { _, isOn in
                        if isOn { appState.translateMissing() }
                    }

                Picker(loc[.translateTo], selection: $settings.translationTarget) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(loc.name(of: language)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!settings.translationEnabled)
                .onChange(of: settings.translationTarget) { _, _ in
                    appState.retranslateAll()
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct StatusPill: View {
    let state: SessionCoordinator.State
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .idle: return .secondary
        case .connecting, .reconnecting: return .orange
        case .listening: return .green
        case .failed: return .red
        }
    }
}
