import Playgrounds
import SwiftUI

/// Root of the app: the same vocabulary drives both engines so they can be compared side by side.
struct ContentView: View {
    @State private var vocabulary = VocabularyStore()

    var body: some View {
        TabView {
            Tab("Local", systemImage: "iphone") {
                LocalTranscriptionView(vocabulary: vocabulary)
            }
            Tab("Whisper", systemImage: "cloud") {
                WhisperTranscriptionView(vocabulary: vocabulary)
            }
            Tab("Whisper Live", systemImage: "waveform") {
                WhisperLiveTranscriptionView(vocabulary: vocabulary)
            }
        }
    }
}

/// On-device transcription with SpeechAnalyzer / DictationTranscriber.
struct LocalTranscriptionView: View {
    let vocabulary: VocabularyStore
    @State private var model = SpeechTranscriptionModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcript") {
                    TextEditor(text: $model.transcript)
                        .frame(minHeight: 220)

                    if model.isPreparingModel {
                        HStack {
                            ProgressView()
                            Text("Downloading speech model…")
                        }
                    }

                    if let errorMessage = model.errorMessage {
                        ErrorText(errorMessage)
                    }

                    RecordButton(isRecording: model.isRecording) {
                        Task { await model.toggleRecording(vocabulary: vocabulary.cleanedTerms) }
                    }
                }

                VocabularySection(vocabulary: vocabulary)
            }
            .formStyle(.grouped)
            .navigationTitle("Local")
        }
    }
}

/// Cloud transcription with Whisper on Vertex AI, via the `transcribe` Cloud Function.
struct WhisperTranscriptionView: View {
    let vocabulary: VocabularyStore
    @State private var model = WhisperTranscriptionModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcript") {
                    TextEditor(text: $model.transcript)
                        .frame(minHeight: 220)

                    if model.isUploading {
                        HStack {
                            ProgressView()
                            Text("Transcribing with Whisper…")
                        }
                    }

                    if let raw = model.lastRawText, !raw.isEmpty {
                        Text("Raw Whisper: \(raw)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let latency = model.lastClientLatency {
                        let server = model.lastServerLatencyMs.map { " · server \($0) ms" } ?? ""
                        Text("Round trip \(latency.formatted(.units(allowed: [.seconds, .milliseconds])))\(server)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage = model.errorMessage {
                        ErrorText(errorMessage)
                    }

                    RecordButton(isRecording: model.isRecording) {
                        Task { await model.toggleRecording(vocabulary: vocabulary.cleanedTerms) }
                    }
                    .disabled(model.isUploading)
                }

                VocabularySection(vocabulary: vocabulary)
            }
            .formStyle(.grouped)
            .navigationTitle("Whisper")
        }
    }
}

/// Streaming Whisper over WebSocket (Cloud Run GPU): text appears while you speak.
struct WhisperLiveTranscriptionView: View {
    let vocabulary: VocabularyStore
    @State private var model = WhisperLiveTranscriptionModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcript") {
                    TextEditor(text: $model.transcript)
                        .frame(minHeight: 220)

                    if model.isConnecting {
                        HStack {
                            ProgressView()
                            Text("Connecting… (first connection can take ~1 min while the GPU starts)")
                        }
                    } else if model.isFinishing {
                        HStack {
                            ProgressView()
                            Text("Finishing…")
                        }
                    }

                    if let inferenceMs = model.lastInferenceMs {
                        Text("Last pass \(inferenceMs) ms")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage = model.errorMessage {
                        ErrorText(errorMessage)
                    }

                    RecordButton(isRecording: model.isRecording) {
                        Task { await model.toggleRecording(vocabulary: vocabulary.cleanedTerms) }
                    }
                    .disabled(model.isConnecting || model.isFinishing)
                }

                VocabularySection(vocabulary: vocabulary)
            }
            .formStyle(.grouped)
            .navigationTitle("Whisper Live")
        }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                isRecording ? "Stop Recording" : "Start Recording",
                systemImage: isRecording ? "stop.fill" : "mic.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .accentColor)
        .controlSize(.large)
    }
}

private struct ErrorText: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

/// Compact entry point to the vocabulary, so the transcript and record button stay on screen.
private struct VocabularySection: View {
    let vocabulary: VocabularyStore

    var body: some View {
        Section {
            NavigationLink {
                VocabularyListView(vocabulary: vocabulary)
            } label: {
                LabeledContent("Custom Vocabulary", value: "\(vocabulary.terms.count) terms")
            }
        }
    }
}

/// Scrollable, searchable list of the shared vocabulary terms.
private struct VocabularyListView: View {
    let vocabulary: VocabularyStore
    @State private var newTerm = ""
    @State private var searchText = ""

    private var filteredTerms: [String] {
        guard !searchText.isEmpty else { return vocabulary.terms }
        return vocabulary.terms.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add a word or phrase", text: $newTerm)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("\(filteredTerms.count) terms") {
                ForEach(filteredTerms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        #if os(macOS)
                        Button(role: .destructive) {
                            vocabulary.remove(term)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        #endif
                    }
                }
                .onDelete { offsets in
                    for term in offsets.map({ filteredTerms[$0] }) {
                        vocabulary.remove(term)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search terms")
        .navigationTitle("Custom Vocabulary")
    }

    private func addTerm() {
        vocabulary.add(newTerm)
        newTerm = ""
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
