import AVFoundation
import Foundation

/// 結果を端末内蔵の声（AVSpeechSynthesizer）で読み上げる。ネット不要・遅延ゼロ。
///
/// ブロスタの BGM を消さずにかぶせたいので、オーディオセッションは
/// `.playback` + `.duckOthers` + `.mixWithOthers` で構成する。
final class SpeechAnnouncer: ObservableObject {
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

    private init() {}

    /// 直前の読み上げを打ち切って、新しい内容を読む。
    /// ドラフトは数秒で進むので、古い提案を読み続けない方が実戦的。
    func announce(_ segments: [Recommendation.SpeechSegment]) {
        guard AppSettings.speechEnabled, !segments.isEmpty else { return }
        stop()
        configureSession()
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

    /// 動作確認用。短い単語だけだと声の自然さが分かりにくいので、
    /// 実際のおすすめ読み上げ（Recommender.speechSegments）と同じ組み立て方・長さの
    /// サンプル文を読ませる。
    ///
    /// 「相手ゴミピックすぎる」のような相手を煽るセリフは、ブラインドピックでは
    /// 相手が見えないため本番の読み上げにはまだ出せない（エリート帯の相手公開に対応したら
    /// HypeCommentary 側に追加する）。ここではあくまで声の雰囲気を試せるように、
    /// テスト専用でそのトーンのセリフも混ぜてある。
    func announceTest() {
        announce([
            .init(text: "おすすめ、", isJapanese: true),
            .init(text: "シェリー", isJapanese: true),
            .init(text: "。理由は、相手構成に近距離アタッカーが不足しているため、"
                       + "序盤の接近戦を制圧しやすいです", isJapanese: true),
            .init(text: "。立ち回りは、茂みや壁の裏に隠れて、孤立した相手や後衛だけを狙おう。"
                       + "正面から撃ち合うと不利なので、飛び込む隙を待つのがコツ。", isJapanese: true),
            .init(text: "。相手ピック、正直ゴミすぎるて。これ選んだら普通に勝てるわ。"
                       + "これで負けたらエリ止まり確定やろ。", isJapanese: true),
            .init(text: "二位、", isJapanese: true),
            .init(text: "エドガー", isJapanese: true),
            .init(text: "。", isJapanese: true)
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
