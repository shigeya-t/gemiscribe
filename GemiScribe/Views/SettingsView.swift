import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Localizer.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = KeychainStore.loadAPIKey() ?? ""
    @State private var testState: TestState = .idle
    @State private var didCopyCommit = false

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = appState.settings

        VStack(spacing: 0) {
            Form {
                Section(loc[.apiKeySection]) {
                    SecureField(loc[.apiKey], text: $apiKey, prompt: Text(loc[.apiKeyPlaceholder]))
                        .onChange(of: apiKey) { _, newValue in
                            KeychainStore.saveAPIKey(newValue)
                            testState = .idle
                        }
                    HStack {
                        Text(loc[.apiKeyHelp]).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Link(loc[.getApiKey], destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(.caption)
                    }

                    HStack(spacing: 10) {
                        Button(testState == .running ? loc[.testing] : loc[.testConnection]) {
                            runConnectionTest()
                        }
                        .disabled(apiKey.isEmpty || testState == .running)

                        switch testState {
                        case .idle:
                            EmptyView()
                        case .running:
                            ProgressView().controlSize(.small)
                        case .succeeded:
                            Label(loc[.testSuccess], systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failed(let message):
                            Label(loc.format(.testFailedFormat, message), systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }

                Section(loc[.modelsSection]) {
                    TextField(loc[.transcribeModel], text: $settings.transcribeModel)
                    TextField(loc[.translateModel], text: $settings.translateModel)
                }

                Section(loc[.vocabularySection]) {
                    // TextEditor has no prompt of its own; a dimmed sample sits on top
                    // until the first character is typed, so the expected format —
                    // one term per line, or comma-separated — is visible before typing.
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $settings.customVocabularyText)
                            .font(.body)
                            .frame(minHeight: 70)
                        if settings.customVocabularyText.isEmpty {
                            Text(loc[.customVocabularyPlaceholder])
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    Text(loc[.customVocabularyHelp]).font(.caption).foregroundStyle(.secondary)
                }

                Section(loc[.advancedSection]) {
                    LabeledContent(loc[.silenceDuration]) {
                        HStack {
                            Slider(value: silenceDurationBinding(settings), in: 300...2000, step: 50)
                                .frame(width: 180)
                            Text("\(settings.silenceDurationMs) ms")
                                .monospacedDigit()
                                .font(.caption)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                    Text(loc[.silenceDurationHelp]).font(.caption).foregroundStyle(.secondary)

                    LabeledContent(loc[.silenceThreshold]) {
                        HStack {
                            Slider(value: $settings.silenceThresholdDB, in: -70 ... -20, step: 1)
                                .frame(width: 180)
                            Text("\(Int(settings.silenceThresholdDB)) dB")
                                .monospacedDigit()
                                .font(.caption)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                    Text(loc[.silenceThresholdHelp]).font(.caption).foregroundStyle(.secondary)

                    // With --debug on the command line the toggle would otherwise read
                    // "off" while the app is very much logging.
                    Toggle(loc[.debugLogging],
                           isOn: settings.isDebugLoggingForced
                               ? .constant(true)
                               : $settings.debugLogging)
                        .toggleStyle(.switch)
                        .disabled(settings.isDebugLoggingForced)
                    Text(settings.isDebugLoggingForced
                         ? loc[.debugLoggingForced]
                         : loc[.debugLoggingHelp])
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(loc[.resetDefaults]) { settings.resetAdvancedToDefaults() }
                }

                // Which build this is. A rebuilt app only takes effect once the running
                // process is replaced, and the two are indistinguishable on screen.
                Section(loc[.buildSection]) {
                    LabeledContent(loc[.buildVersion], value: BuildInfo.version)
                    LabeledContent(loc[.buildCommit]) {
                        HStack(spacing: 6) {
                            Text(BuildInfo.commit)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                appState.copy(BuildInfo.commit)
                                didCopyCommit = true
                            } label: {
                                Image(systemName: didCopyCommit ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(loc[didCopyCommit ? .buildCopied : .buildCommit])
                        }
                    }
                    LabeledContent(loc[.buildDate], value: BuildInfo.builtAt)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(loc[.close]) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
    }

    private func silenceDurationBinding(_ settings: AppSettings) -> Binding<Double> {
        Binding(
            get: { Double(settings.silenceDurationMs) },
            set: { settings.silenceDurationMs = Int($0) }
        )
    }

    private func runConnectionTest() {
        testState = .running
        let key = apiKey
        let model = appState.settings.translateModel
        Task {
            do {
                try await TranslationService.verify(apiKey: key, model: model)
                testState = .succeeded
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
