import AVFoundation

/// 日本語音声の選定ロジック（Premium > Enhanced > 既定）。
/// SpeechAnnouncer（結果読み上げ）と VoiceAssistant（対話モード）の両方から使う。
enum VoiceCatalog {
    static let japanese: AVSpeechSynthesisVoice? = {
        let ja = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") }
        return ja.first { $0.quality == .premium }
            ?? ja.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }()
}
