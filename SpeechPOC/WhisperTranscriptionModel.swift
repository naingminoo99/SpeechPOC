import AVFoundation
import Observation

/// Records an utterance to a compact AAC file and, on stop, sends it to the `transcribe` Cloud
/// Function, which forwards it to Whisper hosted on a Vertex AI endpoint.
///
/// Whisper is a batch model, so text arrives once per recording rather than streaming. The server
/// turns the vocabulary into Whisper's initial prompt (a soft bias, Whisper's closest equivalent to
/// the Local tab's contextual strings / trained language model) and then normalizes the output
/// against it (known mishearings, fuzzy snapping) — see cloud/whisper-server/vocab.py.
@MainActor
@Observable
final class WhisperTranscriptionModel {

    /// The text shown (and freely editable) in the UI's text box.
    var transcript: String = ""

    var isRecording = false
    var isUploading = false
    var errorMessage: String?

    /// Whisper's output for the last recording before server-side normalization, for comparison.
    var lastRawText: String?

    /// Round trip of the last request as measured by the app, and the server's share of it.
    var lastClientLatency: Duration?
    var lastServerLatencyMs: Int?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func toggleRecording(vocabulary: [String]) async {
        if isRecording {
            await stopAndTranscribe(vocabulary: vocabulary)
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        errorMessage = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access was denied. Enable it in Settings to record."
            return
        }

        do {
            #if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            #endif

            // Whisper resamples to 16 kHz mono internally, so recording at that rate loses nothing the
            // model would use. 32 kbps AAC (~240 KB/min) keeps a ~4 min recording under Vertex's
            // 1.5 MB online-prediction request limit once base64-encoded.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ]

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                errorMessage = "Couldn't start recording."
                return
            }

            self.recorder = recorder
            self.recordingURL = url
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopAndTranscribe(vocabulary: [String]) async {
        guard isRecording, let recorder, let recordingURL else { return }
        isRecording = false

        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        defer { try? FileManager.default.removeItem(at: recordingURL) }

        isUploading = true
        defer { isUploading = false }

        do {
            let audio = try Data(contentsOf: recordingURL)
            let clock = ContinuousClock()
            let start = clock.now
            let response = try await WhisperClient.transcribe(audio: audio, terms: vocabulary)
            lastClientLatency = clock.now - start
            lastServerLatencyMs = response.latencyMs
            lastRawText = response.rawText

            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                transcript += (transcript.isEmpty ? "" : " ") + text
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Minimal multipart client for the `transcribe` Cloud Function.
enum WhisperClient {

    struct Response: Decodable {
        let text: String
        let rawText: String?
        let latencyMs: Int?
    }

    struct ServerError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "Whisper request failed (\(status)): \(body)" }
    }

    static func transcribe(audio: Data, terms: [String]) async throws -> Response {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }

        appendField("terms", terms.joined(separator: "\n"))
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: WhisperSecrets.transcribeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(WhisperSecrets.pocToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw ServerError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
