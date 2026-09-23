import AVFoundation
import Foundation

/// 結果を日本語で読み上げる。
///
/// ブロスタの BGM を消さずにかぶせたいので、オーディオセッションは
/// `.playback` + `.duckOthers` + `.mixWithOthers` で構成する。
final class SpeechAnnouncer {
    static let shared = SpeechAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    private lazy var japaneseVoice: AVSpeechSynthesisVoice? = {
        // 高品質な声があればそれを使う
        let ja = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") }
        return ja.first { $0.quality == .premium }
            ?? ja.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }()
    private lazy var englishVoice: AVSpeechSynthesisVoice? =
        AVSpeechSynthesisVoice(language: "en-US")

    private init() {}

    /// 直前の読み上げを打ち切って、新しい内容を読む。
    /// ドラフトは数秒で進むので、古い提案を読み続けない方が実戦的。
    func announce(_ segments: [Recommendation.SpeechSegment]) {
        guard AppSettings.speechEnabled, !segments.isEmpty else { return }
        configureSession()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let rate = Float(AppSettings.speechRate)
        for segment in segments {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = segment.isJapanese ? japaneseVoice : englishVoice
            utterance.rate = rate
            utterance.pitchMultiplier = 1.05
            utterance.preUtteranceDelay = 0
            utterance.postUtteranceDelay = 0
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 動作確認用
    func announceTest() {
        announce([
            .init(text: "テスト。ラスト、", isJapanese: true),
            .init(text: "パイパー。", isJapanese: true)
        ])
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // 音が出せなくても通知バナーは出るので致命的ではない
        }
    }
}
