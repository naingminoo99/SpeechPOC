import Playgrounds
import SwiftUI

struct ContentView: View {
    @State private var model = SpeechTranscriptionModel()
    @State private var newVocabularyTerm = ""

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
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await model.toggleRecording() }
                    } label: {
                        Label(
                            model.isRecording ? "Stop Recording" : "Start Recording",
                            systemImage: model.isRecording ? "stop.fill" : "mic.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isRecording ? .red : .accentColor)
                    .controlSize(.large)
                }

                Section("Custom Vocabulary") {
                    ForEach(model.vocabulary, id: \.self) { term in
                        Text(term)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            model.removeVocabularyTerm(model.vocabulary[index])
                        }
                    }

                    HStack {
                        TextField("Add a word or phrase", text: $newVocabularyTerm)
                        Button("Add") {
                            model.addVocabularyTerm(newVocabularyTerm)
                            newVocabularyTerm = ""
                        }
                        .disabled(newVocabularyTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Speech POC")
        }
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
