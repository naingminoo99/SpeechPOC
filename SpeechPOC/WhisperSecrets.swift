import Foundation

/// POC-only secrets. Gitignored — see cloud/WhisperSecrets.swift.example.
enum WhisperSecrets {
    static let transcribeURL = URL(string: "https://asia-southeast1-speechpoc-whisper.cloudfunctions.net/transcribe")!
    static let streamURL = URL(string: "wss://whisper-live-760247120919.asia-southeast1.run.app/stream")!
    static let pocToken = "7PCv0ifh701Md_UFm7k4qVNJ7f45Ugt4K-oBxHTIKb4"
}
