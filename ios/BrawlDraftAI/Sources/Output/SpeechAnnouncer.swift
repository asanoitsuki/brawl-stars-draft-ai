import AVFoundation
import Foundation

/// 結果を読み上げる。2 つの方式を切り替えられる。
///
///   * 端末内蔵（既定）: AVSpeechSynthesizer。ネット不要・遅延ゼロだが機械的な声。
///   * ElevenLabs: 自然な声だが API キーとネットワークが要る。テキストごとにディスクへ
///     キャッシュするので、キャラ名のような閉じた語彙は 2 回目以降ネット無しで即再生できる。
///     合成に失敗したとき（オフライン・キー未設定・レート制限など）は端末内蔵の声に自動で
///     切り替える — 対戦中に無音になるよりは機械声の方がマシという判断。
///
/// ブロスタの BGM を消さずにかぶせたいので、オーディオセッションは
/// `.playback` + `.duckOthers` + `.mixWithOthers` で構成する。
final class SpeechAnnouncer {
    static let shared = SpeechAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    private lazy var japaneseVoice: AVSpeechSynthesisVoice? = {
        let ja = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") }
        return ja.first { $0.quality == .premium }
            ?? ja.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }()
    private lazy var englishVoice: AVSpeechSynthesisVoice? =
        AVSpeechSynthesisVoice(language: "en-US")

    private var cloudTask: Task<Void, Never>?
    private var cloudPlayer: AVQueuePlayer?

    private init() {}

    /// 直前の読み上げを打ち切って、新しい内容を読む。
    /// ドラフトは数秒で進むので、古い提案を読み続けない方が実戦的。
    func announce(_ segments: [Recommendation.SpeechSegment]) {
        guard AppSettings.speechEnabled, !segments.isEmpty else { return }
        stop()
        configureSession()

        switch AppSettings.speechBackend {
        case .onDevice:
            speakOnDevice(segments)
        case .elevenLabs:
            guard AppSettings.isElevenLabsConfigured else {
                speakOnDevice(segments)  // 未設定なら黙って端末内蔵にフォールバック
                return
            }
            cloudTask = Task { [weak self] in
                await self?.speakCloud(segments)
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        cloudTask?.cancel()
        cloudTask = nil
        cloudPlayer?.pause()
        cloudPlayer?.removeAllItems()
        cloudPlayer = nil
    }

    /// 動作確認用
    func announceTest() {
        announce([
            .init(text: "テスト。ラスト、", isJapanese: true),
            .init(text: "パイパー。", isJapanese: true)
        ])
    }

    // MARK: - 端末内蔵

    private func speakOnDevice(_ segments: [Recommendation.SpeechSegment]) {
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

    // MARK: - ElevenLabs

    private func speakCloud(_ segments: [Recommendation.SpeechSegment]) async {
        var urls: [URL] = []
        for segment in segments {
            guard !Task.isCancelled else { return }
            guard !segment.text.isEmpty else { continue }
            do {
                urls.append(try await SpeechCache.fileURL(for: segment.text))
            } catch {
                // 1 か所でも合成に失敗したら、部分的にクラウド・部分的に機械音声という
                // ちぐはぐな結果になるより、丸ごと端末内蔵にフォールバックした方が聞きやすい。
                guard !Task.isCancelled else { return }
                await MainActor.run { self.speakOnDevice(segments) }
                return
            }
        }
        guard !Task.isCancelled, !urls.isEmpty else { return }

        await MainActor.run {
            let items = urls.map { AVPlayerItem(url: $0) }
            let player = AVQueuePlayer(items: items)
            player.actionAtItemEnd = .advance
            self.cloudPlayer = player
            player.play()
        }
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
