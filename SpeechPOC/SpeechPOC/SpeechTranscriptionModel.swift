import AVFoundation
import Observation
import Speech

/// Drives the SpeechAnalyzer / SpeechTranscriber pipeline for the POC.
///
/// Requires iOS/iPadOS 27 on a physical device (SpeechAnalyzer does not run in the Simulator).
@MainActor
@Observable
final class SpeechTranscriptionModel {

    /// The text shown (and freely editable) in the UI's text box.
    var transcript: String = ""

    /// Custom vocabulary terms biased towards during recognition.
    var vocabulary: [String] = [
        "Paiza Chairman",
        "Paiza Diamond",
        "Sands Lifestyle",
        "SRC",
        "Sands Rewards Club",
        "GRA"
    ]

    var isRecording = false
    var isPreparingModel = false
    var errorMessage: String?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var captureSession: AVCaptureSession?
    private var resultsTask: Task<Void, Never>?

    /// Text already committed to `transcript` before/between recording sessions.
    private var finalizedText: String = ""

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        errorMessage = nil

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Microphone access was denied. Enable it in Settings to record."
            return
        }

        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                errorMessage = "Speech transcription isn't supported for the current locale."
                return
            }

            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

            if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                isPreparingModel = true
                try await installationRequest.downloadAndInstall()
                isPreparingModel = false
            }

            guard let captureDevice = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) else {
                errorMessage = "No microphone is available on this device."
                return
            }

            let provider = try await CaptureInputSequenceProvider.providerWithSession(
                from: captureDevice,
                compatibleWith: [transcriber]
            )

            let context = AnalysisContext()
            let terms = vocabulary
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            context.contextualStrings[.general] = terms

            let analyzer = SpeechAnalyzer(
                inputSequence: provider.analyzerInputs,
                modules: [transcriber],
                analysisContext: context
            )

            self.transcriber = transcriber
            self.analyzer = analyzer
            self.captureSession = provider.captureSession
            finalizedText = transcript

            resultsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await result in transcriber.results {
                        self.handle(result: result)
                    }
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }

            provider.captureSession.startRunning()
            isRecording = true
        } catch {
            isPreparingModel = false
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        guard isRecording else { return }
        isRecording = false

        captureSession?.stopRunning()
        captureSession = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            errorMessage = error.localizedDescription
        }

        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    private func handle(result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)

        if result.isFinal {
            if !text.isEmpty {
                finalizedText += (finalizedText.isEmpty ? "" : " ") + text
            }
            transcript = finalizedText
        } else {
            transcript = finalizedText + (finalizedText.isEmpty || text.isEmpty ? "" : " ") + text
        }
    }

    func addVocabularyTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vocabulary.contains(trimmed) else { return }
        vocabulary.append(trimmed)
    }

    func removeVocabularyTerm(_ term: String) {
        vocabulary.removeAll { $0 == term }
    }
}
