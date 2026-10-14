import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var reader: Reader
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-...", text: $settings.anthropicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Create one at console.anthropic.com. It's stored in your iPhone's Keychain and sent only to Anthropic.")
                }

                Section("Answers") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(Models.all, id: \.id) { m in Text(m.name).tag(m.id) }
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $settings.thinkHarder) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Think harder")
                            Text("Claude works through it privately first. Slower, more accurate on diagrams and multi-step problems.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    Picker("Photo detail", selection: $settings.photoDetail) {
                        ForEach(PhotoDetail.allCases) { d in Text(d.title).tag(d) }
                    }
                    Text(settings.photoDetail.note + (Models.highRes(settings.model) ? "" : " Haiku sees photos at standard size."))
                        .font(.footnote).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extra instructions").font(.footnote).foregroundStyle(Theme.muted)
                        TextField("Use radians. Round to 3 decimal places.", text: $settings.extra, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }

                Section {
                    Picker("Voice engine", selection: $settings.engine) {
                        ForEach(VoiceEngine.allCases) { e in Text(e.title).tag(e) }
                    }
                    .pickerStyle(.segmented)
                    if settings.engine == .device {
                        Picker("iPhone voice", selection: $settings.voiceID) {
                            Text("Best available").tag("")
                            ForEach(voices, id: \.identifier) { v in
                                Text("\(v.name) · \(Reader.qualityLabel(v)) · \(v.language)").tag(v.identifier)
                            }
                        }
                        Button("Test voice") { reader.test(["This is how your answers will sound.", "x equals negative 3 over 4."]) }
                    } else {
                        SecureField("Google API key (AIza...)", text: $settings.googleKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Picker("Google voice", selection: $settings.googleVoice) {
                            ForEach(GoogleTTS.voices, id: \.name) { v in
                                Text("\(v.name) (\(v.gender))").tag("en-US-Chirp3-HD-" + v.name)
                            }
                        }
                        Button("Test Google voice") { model.testGoogle() }
                        Text(model.googleStatus).font(.footnote)
                            .foregroundStyle(model.googleStatusOK == true ? Theme.amber : model.googleStatusOK == false ? Theme.danger : Theme.muted)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Used this month").font(.footnote).foregroundStyle(Theme.muted)
                                Spacer()
                                Text("\(GoogleTTS.usage().formatted()) of 1,000,000").font(.footnote.monospacedDigit())
                            }
                            ProgressView(value: min(1, Double(GoogleTTS.usage()) / 1_000_000))
                        }
                        Toggle(isOn: $settings.googleCap) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stay in the free tier")
                                Text("Switches to the iPhone voice after 950,000 characters this month. Repeats replay saved audio, so they don't count.")
                                    .font(.footnote).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("Speed"); Spacer(); Text(String(format: "%.2f×", settings.rate)).monospacedDigit().foregroundStyle(Theme.muted) }
                        Slider(value: $settings.rate, in: 0.5...1.3, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("Volume"); Spacer(); Text("\(Int(settings.volume * 100))%").monospacedDigit().foregroundStyle(Theme.muted) }
                        Slider(value: $settings.volume, in: 0...1, step: 0.05)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    if settings.engine == .device {
                        Text("For a much more natural voice, download one in iPhone Settings > Accessibility > Spoken Content (or Read & Speak) > Voices > English. Premium voices sound best. They show up here once downloaded.")
                    }
                }

                Section("Reading") {
                    Picker("Repeat each answer", selection: $settings.repeats) {
                        Text("Once").tag(1)
                        Text("Twice").tag(2)
                        Text("3 times").tag(3)
                    }
                    Picker("On repeats, read", selection: $settings.repeatWhat) {
                        ForEach(RepeatWhat.allCases) { r in Text(r.title).tag(r) }
                    }
                    Picker("Pause between lines", selection: $settings.pauseMs) {
                        Text("Short").tag(500)
                        Text("Medium").tag(1200)
                        Text("Long").tag(2500)
                    }
                    Picker("Pause between terms", selection: $settings.termPauseMs) {
                        Text("Off").tag(0)
                        Text("Short").tag(350)
                        Text("Medium").tag(650)
                        Text("Long").tag(1100)
                    }
                    Toggle("Read the worked steps too", isOn: $settings.readSteps)
                    Toggle("Say \"again\" before each repeat", isOn: $settings.sayAgain)
                    Toggle("Sound cues", isOn: $settings.cues)
                }

                Section {
                    Toggle("Answer automatically", isOn: $settings.auto)
                    Toggle("Wait until reading is done", isOn: $settings.waitForVoice)
                    Picker("Hold time", selection: $settings.holdMs) {
                        Text("Quick").tag(600)
                        Text("Normal").tag(900)
                        Text("Patient").tag(1400)
                    }
                } header: {
                    Text("Auto answer")
                } footer: {
                    Text("Move to a new question and hold still. It only fires when it sees text in the brackets, and waits for the current answer to finish.")
                }

                Section("Saved answers") {
                    Toggle("Save answers on this iPhone", isOn: $settings.keepHistory)
                    Button("Clear saved answers", role: .destructive) { confirmClear = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear all saved answers?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear saved answers", role: .destructive) { model.clearHistory() }
            }
        }
        .onAppear { voices = Reader.englishVoices() }
    }
}

struct SavedView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(Theme.muted)
                        Text("No saved answers yet").font(.headline)
                        Text("Every answer you scan shows up here, so you can hear it again.").font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    List(model.history) { e in
                        Button { model.open(e) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(e.title).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                                    Spacer()
                                    Text(e.ts.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(Theme.muted)
                                }
                                Text(e.answerSummary).font(.system(.body, design: .serif)).foregroundStyle(Theme.text).lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
            .navigationTitle("Saved answers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
