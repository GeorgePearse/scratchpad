import ScratchKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: PadSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Anthropic API key", text: $settings.apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Model", selection: $settings.modelID) {
                        ForEach(ClaudeModelInfo.all) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Picker("Effort", selection: $settings.effort) {
                        ForEach(ClaudeModel.Effort.allCases, id: \.self) { effort in
                            Text(effort.rawValue.capitalized).tag(effort)
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("\(ClaudeModelInfo.named(settings.modelID)?.note ?? "") Lower effort answers sooner. The key is kept in this iPad's keychain and sent only to Anthropic.")
                }

                Section {
                    LabeledContent("Wait after a stroke") {
                        Text("\(settings.settleSeconds.formatted(.number.precision(.fractionLength(1)))) s")
                            .monospacedDigit()
                    }
                    Slider(value: $settings.settleSeconds, in: 0...2, step: 0.1) {
                        Text("Wait after a stroke")
                    } minimumValueLabel: {
                        Image(systemName: "hare")
                    } maximumValueLabel: {
                        Image(systemName: "tortoise")
                    }
                    Toggle("Draw with a finger", isOn: $settings.fingerDraws)
                } header: {
                    Text("Pencil")
                } footer: {
                    Text("The model looks at the canvas once the Pencil has been lifted for this long. Shorter is snappier but can catch a word half written. Turn finger drawing off to make the pad Pencil-only; a finger then drags shapes around instead.")
                }

                Section {
                    TextField("For example: keep every box the same size", text: $settings.instructions, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Standing instructions")
                } footer: {
                    Text("Sent to the model with every pass.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
