import AVFoundation
import Observation
import Speech

/// Drives the SpeechAnalyzer / DictationTranscriber pipeline for the POC.
///
/// Requires iOS/iPadOS 27 on a physical device (SpeechAnalyzer does not run in the Simulator).
///
/// Custom vocabulary is prioritized two ways, per Apple's guidance for improving transcriber
/// accuracy: a lightweight `AnalysisContext.contextualStrings` bias, *and* a trained
/// `SFSpeechLanguageModel` built from the same terms and attached via
/// `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)`. The trained model
/// is the mechanism that actually re-weights the language model's word probabilities; the
/// contextual strings alone are a soft hint and are not enough to reliably win out over common
/// dictionary words.
@MainActor
@Observable
final class SpeechTranscriptionModel {

    /// The text shown (and freely editable) in the UI's text box.
    var transcript: String = ""

    var isRecording = false
    var isPreparingModel = false
    var errorMessage: String?

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var captureSession: AVCaptureSession?
    private var resultsTask: Task<Void, Never>?

    /// Text already committed to `transcript` before/between recording sessions.
    private var finalizedText: String = ""

    /// Cached trained language model, rebuilt only when `vocabulary` actually changes.
    private var languageModelConfiguration: SFSpeechLanguageModel.Configuration?
    private var languageModelVocabularySnapshot: [String] = []

    /// - Parameter vocabulary: Custom terms biased towards during recognition.
    func toggleRecording(vocabulary: [String]) async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording(vocabulary: vocabulary)
        }
    }

    private func startRecording(vocabulary: [String]) async {
        errorMessage = nil

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Microphone access was denied. Enable it in Settings to record."
            return
        }

        do {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                errorMessage = "Speech transcription isn't supported for the current locale."
                return
            }

            isPreparingModel = true
            let lmConfiguration = try await preparedLanguageModelConfiguration(locale: locale, vocabulary: vocabulary)
            isPreparingModel = false

            let preset = DictationTranscriber.Preset.progressiveLongDictation
            let contentHints: Set<DictationTranscriber.ContentHint> = if let lmConfiguration {
                preset.contentHints.union([.customizedLanguage(modelConfiguration: lmConfiguration)])
            } else {
                preset.contentHints
            }

            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: contentHints,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions,
                attributeOptions: preset.attributeOptions
            )

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

            // Also bias recognition towards the same terms; a lighter-weight complement to the
            // trained language model above.
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary

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

    private func handle(result: DictationTranscriber.Result) {
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

    /// Builds (or reuses a cached) trained language model that strongly biases recognition
    /// towards `vocabulary`. Rebuilding only happens when the vocabulary list has changed since
    /// the last build, since training and exporting is not free.
    private func preparedLanguageModelConfiguration(
        locale: Locale,
        vocabulary terms: [String]
    ) async throws -> SFSpeechLanguageModel.Configuration? {
        guard !terms.isEmpty else { return nil }

        if let configuration = languageModelConfiguration, languageModelVocabularySnapshot == terms {
            return configuration
        }

        let appSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelURL = appSupportDirectory.appendingPathComponent("SpeechPOCCustomVocabulary.bin")
        let vocabularyURL = appSupportDirectory.appendingPathComponent("SpeechPOCCustomVocabulary.vocab")

        let trainingData = SFCustomLanguageModelData(
            locale: locale,
            identifier: "com.speechpoc.customvocabulary",
            version: UUID().uuidString
        )

        for term in terms {
            // The full phrase gets the strongest weight so it's preferred as a single unit.
            trainingData.insert(phraseCount: .init(phrase: term, count: 1000))

            // Individual words also get a boost, so distinctive terms (e.g. "Paiza", "GRA") are
            // still favored when spoken on their own, not just as part of the full phrase.
            let words = term.split(separator: " ").map(String.init)
            if words.count > 1 {
                for word in words {
                    trainingData.insert(phraseCount: .init(phrase: word, count: 300))
                }
            }
        }

        let trainingDataURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await trainingData.export(to: trainingDataURL)
        defer { try? FileManager.default.removeItem(at: trainingDataURL) }

        let configuration = SFSpeechLanguageModel.Configuration(
            languageModel: modelURL,
            vocabulary: vocabularyURL,
            weight: 0.9
        )
        try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: trainingDataURL, configuration: configuration)

        languageModelConfiguration = configuration
        languageModelVocabularySnapshot = terms
        return configuration
    }
}
