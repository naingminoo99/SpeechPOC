import AVFoundation
import CryptoKit
import Observation
import Speech

/// Which on-device recognizer the Local tab uses.
///
/// Per Apple's docs and DTS answers on the developer forums, only `DictationTranscriber` accepts custom
/// vocabulary (contextual strings and a trained `SFSpeechLanguageModel`); `SpeechTranscriber` is the
/// newer general-purpose model but ignores both. Both get the same vocabulary clean-up afterwards.
enum LocalEngine: String, CaseIterable, Identifiable {
    case dictation
    case speech

    var id: Self { self }

    var title: String {
        switch self {
        case .dictation: "Dictation + vocabulary"
        case .speech: "SpeechTranscriber"
        }
    }
}

/// English variants with on-device models. Singapore English is the default for this POC.
enum LocalLanguage: String, CaseIterable, Identifiable {
    case singapore = "en_SG"
    case unitedStates = "en_US"
    case unitedKingdom = "en_GB"

    var id: Self { self }

    var title: String {
        switch self {
        case .singapore: "English (Singapore)"
        case .unitedStates: "English (US)"
        case .unitedKingdom: "English (UK)"
        }
    }
}

/// Drives the SpeechAnalyzer pipeline for the Local tab.
///
/// Requires iOS/iPadOS/macOS 27 (`CaptureInputSequenceProvider`); does not run in the Simulator.
///
/// Accuracy measures, following Apple's documentation and the "Recognizing speech in live audio" sample:
/// - **Locale**: an explicit English variant instead of the device default (e.g. en_SG).
/// - **Custom language model** (Dictation engine): trained from sentence templates with word classes
///   ("a table at <venue>") plus X-SAMPA pronunciations for unfamiliar names, instead of isolated
///   words — see `VocabularyCatalog`. Weighted with `SFSpeechLanguageModel.Configuration.weight`.
/// - **Contextual strings** (Dictation engine): the same terms as a lighter bias.
/// - **Alternatives**: final results request alternative transcriptions and keep the one that mentions
///   the most vocabulary terms.
/// - **Clean-up**: `VocabularyNormalizer` (port of vocab.py) fixes known mishearings and near-misses.
/// - **Responsiveness**: models and the custom LM are prepared before Start, and the analyzer keeps
///   its model loaded between recordings (`modelRetention: .lingering`).
@MainActor
@Observable
final class SpeechTranscriptionModel {

    /// The text shown (and freely editable) in the UI's text box.
    var transcript: String = ""

    /// This session's final text before vocabulary clean-up, to compare with the cleaned transcript.
    var rawTranscript: String = ""

    var isRecording = false
    var isPreparingModel = false
    var preparationStatus: String?
    var errorMessage: String?

    private enum ActiveTranscriber {
        case dictation(DictationTranscriber)
        case speech(SpeechTranscriber)

        var module: any SpeechModule {
            switch self {
            case .dictation(let transcriber): transcriber
            case .speech(let transcriber): transcriber
            }
        }
    }

    private struct Update {
        let text: String
        let alternatives: [String]
        let isFinal: Bool
    }

    private var analyzer: SpeechAnalyzer?
    private var captureSession: AVCaptureSession?
    private var resultsTask: Task<Void, Never>?

    /// Text already committed to `transcript` before/between recording sessions.
    private var finalizedText: String = ""
    private var normalizer = VocabularyNormalizer(terms: [])

    /// What `prepare` last finished for, so Start can skip work that's already done.
    private var preparedKey: String?
    private var languageModel: SFSpeechLanguageModel.Configuration?

    // MARK: - Preparation

    /// Downloads the speech model and builds the custom language model for this configuration, so
    /// pressing Start is fast. Safe to call repeatedly; it only does work when something changed.
    func prepare(engine: LocalEngine, language: LocalLanguage, vocabulary: [String]) async {
        let key = Self.configurationKey(engine: engine, language: language, vocabulary: vocabulary)
        guard key != preparedKey, !isRecording else { return }

        isPreparingModel = true
        defer {
            isPreparingModel = false
            preparationStatus = nil
        }

        do {
            guard let locale = await Self.supportedLocale(for: language, engine: engine) else {
                errorMessage = "\(language.title) isn't available for \(engine.title) on this device."
                return
            }

            // As in Apple's sample: install the speech model first; training the custom language model
            // needs it on the device.
            preparationStatus = "Checking speech model…"
            let transcriber = Self.makeTranscriber(engine: engine, locale: locale, languageModel: nil)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber.module]) {
                preparationStatus = "Downloading speech model…"
                try await request.downloadAndInstall()
            }

            errorMessage = nil
            languageModel = nil
            if engine == .dictation, !vocabulary.isEmpty {
                preparationStatus = "Training custom vocabulary…"
                do {
                    languageModel = try await Self.preparedLanguageModel(locale: locale, vocabulary: vocabulary)
                } catch {
                    // Still usable: contextual strings and clean-up keep working without the trained model.
                    errorMessage = "Custom vocabulary model couldn't be built (\(error.localizedDescription)). Using hints and clean-up only."
                }
            }

            normalizer = VocabularyNormalizer(terms: vocabulary)
            preparedKey = key
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Recording

    func toggleRecording(engine: LocalEngine, language: LocalLanguage, vocabulary: [String]) async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording(engine: engine, language: language, vocabulary: vocabulary)
        }
    }

    private func startRecording(engine: LocalEngine, language: LocalLanguage, vocabulary: [String]) async {
        errorMessage = nil

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Microphone access was denied. Enable it in Settings to record."
            return
        }

        await prepare(engine: engine, language: language, vocabulary: vocabulary)
        guard preparedKey == Self.configurationKey(engine: engine, language: language, vocabulary: vocabulary),
              let locale = await Self.supportedLocale(for: language, engine: engine)
        else { return }

        do {
            let transcriber = Self.makeTranscriber(engine: engine, locale: locale, languageModel: languageModel)

            guard let captureDevice = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) else {
                errorMessage = "No microphone is available on this device."
                return
            }

            let provider = try await CaptureInputSequenceProvider.providerWithSession(
                from: captureDevice,
                compatibleWith: [transcriber.module]
            )

            // Contextual strings only affect DictationTranscriber; Apple recommends keeping the list short.
            let context = AnalysisContext()
            if engine == .dictation {
                context.contextualStrings[.general] = Array(vocabulary.prefix(100))
            }

            let analyzer = SpeechAnalyzer(
                inputSequence: provider.analyzerInputs,
                modules: [transcriber.module],
                options: .init(priority: .userInitiated, modelRetention: .lingering),
                analysisContext: context
            )

            self.analyzer = analyzer
            self.captureSession = provider.captureSession
            finalizedText = transcript
            rawTranscript = ""

            resultsTask = Task { @MainActor [weak self] in
                do {
                    switch transcriber {
                    case .dictation(let dictation):
                        for try await result in dictation.results {
                            self?.handle(Update(
                                text: String(result.text.characters),
                                alternatives: result.alternatives.map { String($0.characters) },
                                isFinal: result.isFinal
                            ))
                        }
                    case .speech(let speech):
                        for try await result in speech.results {
                            self?.handle(Update(
                                text: String(result.text.characters),
                                alternatives: result.alternatives.map { String($0.characters) },
                                isFinal: result.isFinal
                            ))
                        }
                    }
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }

            provider.captureSession.startRunning()
            isRecording = true
        } catch {
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
    }

    private func handle(_ update: Update) {
        if update.isFinal {
            let chosen = normalizer.bestCandidate(primary: update.text, alternatives: update.alternatives)
            let cleaned = normalizer.normalize(chosen)
            if !chosen.isEmpty {
                rawTranscript += (rawTranscript.isEmpty ? "" : " ") + chosen
            }
            if !cleaned.isEmpty {
                finalizedText += (finalizedText.isEmpty ? "" : " ") + cleaned
            }
            transcript = finalizedText
        } else {
            let volatile = normalizer.normalize(update.text)
            transcript = finalizedText + (finalizedText.isEmpty || volatile.isEmpty ? "" : " ") + volatile
        }
    }

    // MARK: - Building blocks

    private static func makeTranscriber(
        engine: LocalEngine,
        locale: Locale,
        languageModel: SFSpeechLanguageModel.Configuration?
    ) -> ActiveTranscriber {
        switch engine {
        case .dictation:
            let preset = DictationTranscriber.Preset.progressiveLongDictation
            var contentHints = preset.contentHints
            if let languageModel {
                contentHints.insert(.customizedLanguage(modelConfiguration: languageModel))
            }
            return .dictation(DictationTranscriber(
                locale: locale,
                contentHints: contentHints,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions.union([.alternativeTranscriptions]),
                attributeOptions: preset.attributeOptions
            ))
        case .speech:
            let preset = SpeechTranscriber.Preset.progressiveTranscription
            return .speech(SpeechTranscriber(
                locale: locale,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions.union([.alternativeTranscriptions]),
                attributeOptions: preset.attributeOptions
            ))
        }
    }

    private static func supportedLocale(for language: LocalLanguage, engine: LocalEngine) async -> Locale? {
        let requested = Locale(identifier: language.rawValue)
        switch engine {
        case .dictation:
            return await DictationTranscriber.supportedLocale(equivalentTo: requested)
        case .speech:
            guard SpeechTranscriber.isAvailable else { return nil }
            return await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        }
    }

    private static func configurationKey(engine: LocalEngine, language: LocalLanguage, vocabulary: [String]) -> String {
        "\(engine.rawValue)|\(language.rawValue)|\(vocabulary.joined(separator: "\u{1F}"))"
    }

    /// Trains (or reuses from disk) a custom language model for `vocabulary` in `locale`. Files are
    /// named by a hash of locale + terms, so an unchanged vocabulary is never retrained, even across
    /// launches.
    private static func preparedLanguageModel(locale: Locale, vocabulary: [String]) async throws -> SFSpeechLanguageModel.Configuration {
        let fingerprint = SHA256.hash(data: Data((locale.identifier + "\n" + vocabulary.joined(separator: "\n")).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()

        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("CustomLanguageModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let modelURL = directory.appendingPathComponent("vocabulary-\(fingerprint).bin")
        let vocabularyURL = directory.appendingPathComponent("vocabulary-\(fingerprint).vocab")
        let configuration = SFSpeechLanguageModel.Configuration(
            languageModel: modelURL,
            vocabulary: vocabularyURL,
            weight: 0.9
        )

        if FileManager.default.fileExists(atPath: modelURL.path), FileManager.default.fileExists(atPath: vocabularyURL.path) {
            return configuration
        }

        let trainingData = VocabularyCatalog.trainingData(
            locale: locale,
            terms: vocabulary,
            identifier: "com.speechpoc.customvocabulary",
            version: fingerprint
        )
        let trainingDataURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(fingerprint).bin")
        try await trainingData.export(to: trainingDataURL)
        defer { try? FileManager.default.removeItem(at: trainingDataURL) }

        try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: trainingDataURL, configuration: configuration)
        return configuration
    }
}
