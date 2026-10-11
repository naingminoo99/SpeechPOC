import AVFoundation
import Observation

/// Streams microphone audio to the Whisper streaming server (Cloud Run GPU) over a WebSocket and
/// shows text while you speak.
///
/// The server re-transcribes the recent audio about once a second and commits the words two
/// consecutive passes agree on (see cloud/whisper-server/stream_server.py). `committed` text is
/// stable; `pending` is the unconfirmed tail and may still change.
@MainActor
@Observable
final class WhisperLiveTranscriptionModel {

    /// The text shown (and freely editable) in the UI's text box.
    var transcript: String = ""

    var isRecording = false
    var isConnecting = false
    var isFinishing = false
    var errorMessage: String?
    var lastInferenceMs: Int?

    private let audioEngine = AVAudioEngine()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    /// Text committed to `transcript` before this recording session.
    private var finalizedText: String = ""

    private nonisolated static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func toggleRecording(vocabulary: [String]) async {
        if isRecording {
            await stop()
        } else {
            await start(vocabulary: vocabulary)
        }
    }

    private func start(vocabulary: [String]) async {
        errorMessage = nil
        lastInferenceMs = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access was denied. Enable it in Settings to record."
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            #if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            #endif

            var request = URLRequest(url: WhisperSecrets.streamURL)
            request.setValue("Bearer \(WhisperSecrets.pocToken)", forHTTPHeaderField: "Authorization")
            // Generous timeout: a scaled-to-zero GPU instance takes a while to cold start.
            request.timeoutInterval = 120
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()

            let start = try JSONSerialization.data(withJSONObject: [
                "type": "start",
                "terms": vocabulary,
                "language": "en"
            ])
            try await socket.send(.string(String(decoding: start, as: UTF8.self)))

            self.socket = socket
            finalizedText = transcript
            receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }

            try startAudioCapture(sendingTo: socket)
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            tearDown()
        }
    }

    private func stop() async {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // The server finishes the last pass, replies with "final" and closes the socket, which
        // ends the receive loop.
        try? await socket?.send(.string(#"{"type":"stop"}"#))
        await receiveTask?.value
        tearDown()
    }

    private func tearDown() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        receiveTask = nil
        isRecording = false
        isFinishing = false
    }

    // MARK: - Audio

    private func startAudioCapture(sendingTo socket: URLSessionWebSocketTask) throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw LiveError.unsupportedAudioFormat
        }

        Self.installTap(on: input, format: inputFormat, converter: converter, socket: socket)
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Nonisolated so the tap block (called on the audio thread) isn't inferred as main-actor code.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        converter: AVAudioConverter,
        socket: URLSessionWebSocketTask
    ) {
        // ~100 ms buffers, converted to 16 kHz mono PCM16 and sent as binary frames.
        let bufferSize = AVAudioFrameCount(format.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            guard let data = convert(buffer, with: converter) else { return }
            socket.send(.data(data)) { _ in }
        }
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    // MARK: - Server messages

    private struct ServerMessage: Decodable {
        let type: String
        let committed: String?
        let pending: String?
        let text: String?
        let inferenceMs: Int?
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if isRecording {
                    errorMessage = "Connection lost: \(error.localizedDescription)"
                    tearDown()
                }
                return
            }

            guard case .string(let json) = message,
                  let update = try? JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
            else { continue }

            switch update.type {
            case "update":
                lastInferenceMs = update.inferenceMs
                show([update.committed, update.pending])
            case "final":
                show([update.text])
                return
            default:
                break
            }
        }
    }

    private func show(_ parts: [String?]) {
        let session = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        transcript = finalizedText + (finalizedText.isEmpty || session.isEmpty ? "" : " ") + session
    }

    enum LiveError: LocalizedError {
        case unsupportedAudioFormat
        var errorDescription: String? { "The microphone's audio format isn't supported." }
    }
}
