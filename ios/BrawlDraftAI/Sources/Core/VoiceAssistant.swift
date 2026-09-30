import AVFoundation
import Foundation
import Speech
import UIKit

/// マイクで話しかけた内容を聞き取り→回答を声で返す、をこのアプリが前面にある間ずっと繰り返す。
///
/// 想定運用は「スマホでブロスタ本体を操作しながら、iPad など別端末でこのアプリを対話モードで
/// 開いておく」形。スクリーンショット解析は使わず、「このマップになった」「相手、二人はこれを
/// 選んだ」のように状況を声で実況してもらい、そのままドラフト状態を組み立てて次の一手を声で
/// 返す（`DraftDictationSession` が状態管理、`Recommender` が既存のスコアリングを担当）。
/// 状況の実況ではない一般的な質問（「なんで?」「ガジェットは?」など）は `AssistantIntentEngine`
/// に振り分ける。
///
/// iOS の制約上、ブロスタ本体が前面にある間はサードパーティアプリのマイクは使えない
/// （バックグラウンドでの常時マイク録音は OS レベルで禁止・審査でも通らない）。
/// そのため「対話モード」はこのアプリの画面を開いている間だけ会話できる、という設計にしてある
/// （2 台持ち運用なら、この画面はずっと開きっぱなしにできるので実質困らない）。
///
/// 認識は `requiresOnDeviceRecognition` が使える端末では端末内だけで完結させる
/// （プライバシーポリシーの「外部サーバーへ送らない」という説明を裏切らないため）。
@MainActor
final class VoiceAssistant: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case unavailable(String)
    }

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
    }

    static let shared = VoiceAssistant()

    @Published private(set) var state: State = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var turns: [Turn] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var speakCompletion: (() -> Void)?
    private let dictation = DraftDictationSession()

    private var running = false
    private var hasHeardSpeech = false
    private var quietBufferCount = 0

    private override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
    }

    // MARK: - 開始 / 終了

    func start() {
        guard !running else { return }
        dictation.reset()
        turns = []
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.state = .unavailable("音声認識が許可されていません。設定 > プライバシー から許可してください。")
                    return
                }
                self.requestMicAndBegin()
            }
        }
    }

    /// 画面のリセットボタン用。マイクは止めず、これまでの状況（マップ・ピック・会話ログ）
    /// だけ白紙に戻す。音声の「リセット」コマンドと同じ効果。
    func resetConversation() {
        dictation.reset()
        turns = []
        liveTranscript = ""
    }

    func stop() {
        guard running || state != .idle else { return }
        running = false
        synthesizer.stopSpeaking(at: .immediate)
        speakCompletion = nil
        task?.cancel()
        task = nil
        request = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        liveTranscript = ""
    }

    private func requestMicAndBegin() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.state = .unavailable("マイクが許可されていません。設定 > プライバシー から許可してください。")
                    return
                }
                self.running = true
                self.beginListening()
            }
        }
    }

    // MARK: - 1 ターン分の聞き取り

    private func beginListening() {
        guard running else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("この端末・言語では音声認識が使えません。")
            running = false
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            state = .unavailable("マイクの初期化に失敗しました。")
            running = false
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        // キャラ名など一般的でない固有名詞を優先的に聞き取ってもらうためのヒント。
        // Apple の推奨に沿って 100 語前後に収め、最も間違えやすいキャラ名を優先する。
        let hints = contextualHints()
        if !hints.isEmpty { req.contextualStrings = hints }
        request = req
        hasHeardSpeech = false
        quietBufferCount = 0
        liveTranscript = ""

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = rmsLevel(of: buffer)
            Task { @MainActor in
                self?.request?.append(buffer)
                self?.registerAudioLevel(level)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            state = .unavailable("マイクを開始できませんでした。")
            running = false
            return
        }
        state = .listening

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if !self.liveTranscript.isEmpty { self.hasHeardSpeech = true }
                    if result.isFinal { self.handleEndOfUtterance() }
                } else if error != nil {
                    self.handleEndOfUtterance()
                }
            }
        }
    }

    /// 音量が一定水準を下回るバッファが連続したら、発話が終わったとみなして打ち切る。
    /// バッファは 1024 フレーム/44.1kHz ≒ 23ms なので、55 バッファ ≒ 1.3 秒の無音で確定させる。
    /// 「マップは○○、味方はコレとコレを選んだ、相手はコレをバンした」のような長い複合文を
    /// 言い切る前に区切ってしまわないよう、単発の質問より少し長めに待つ。
    private func registerAudioLevel(_ level: Float) {
        guard state == .listening else { return }
        let isQuiet = level < 0.015
        if isQuiet {
            guard hasHeardSpeech else { return }
            quietBufferCount += 1
            if quietBufferCount > 55 {
                quietBufferCount = 0
                request?.endAudio()
            }
        } else {
            quietBufferCount = 0
        }
    }

    /// キャラ名など聞き取りにくい固有名詞を音声認識に優先させるためのヒント一覧。
    private func contextualHints() -> [String] {
        guard let rules = RulesStore.shared.loaded else { return [] }
        var words = rules.document.brawlers.compactMap(\.nameJa)
        words.append(contentsOf: [
            "バン", "禁止", "味方", "相手", "敵", "自チーム",
            "終了", "リセット", "新しいドラフト", "取り消し", "訂正",
            "おすすめ", "ガジェット", "スターパワー", "立ち回り",
            "二位", "三位", "次点", "理由", "マップ", "モード"
        ])
        return words
    }

    private func handleEndOfUtterance() {
        guard running else { return }
        let heard = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        task = nil
        request = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        guard !heard.isEmpty else {
            // 無音や雑音だけだった。何も言わず聞き続ける。
            beginListening()
            return
        }

        state = .thinking
        liveTranscript = ""
        respond(to: heard)
    }

    private func respond(to heard: String) {
        if containsAny(heard, ["やめて", "終了", "ストップ", "もういい", "またね", "ばいばい", "おわり"]) {
            record(question: heard, answer: "対話モードを終了します。")
            speak("対話モードを終了します。") { [weak self] in self?.stop() }
            return
        }
        if containsAny(heard, ["新しいドラフト", "最初から", "リセット", "やり直し"]) {
            dictation.reset()
            let text = "新しいドラフトとして最初から聞きます。"
            record(question: heard, answer: text)
            speak(text) { [weak self] in
                guard let self, self.running else { return }
                self.beginListening()
            }
            return
        }
        if containsAny(heard, ["取り消し", "訂正", "間違えた", "今のなし", "聞き間違い"]) {
            let undone = dictation.undoLast()
            let text = undone.map { "\($0.name)を取り消しました。" } ?? "取り消せる内容がありません。"
            record(question: heard, answer: text)
            speak(text) { [weak self] in
                guard let self, self.running else { return }
                self.beginListening()
            }
            return
        }

        guard let rules = RulesStore.shared.loaded else {
            let text = "まだデータを読み込み中です。少し待ってから聞いてください。"
            record(question: heard, answer: text)
            speak(text) { [weak self] in
                guard let self, self.running else { return }
                self.beginListening()
            }
            return
        }

        let result = dictation.ingest(heard, rules: rules)
        let snapshot = dictation.buildSnapshot()
        let recommendation = Recommender.make(from: snapshot, rules: rules)

        let text = result.changed
            ? confirmationText(result, recommendation: recommendation)
            : AssistantIntentEngine.answer(to: heard, rules: rules, snapshot: snapshot, recommendation: recommendation)

        record(question: heard, answer: text)
        speak(text) { [weak self] in
            guard let self, self.running else { return }
            self.beginListening()
        }
    }

    private func record(question: String, answer: String) {
        turns.append(Turn(question: question, answer: answer))
        if turns.count > 30 { turns.removeFirst(turns.count - 30) }
    }

    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    /// マップ／BAN／ピックの申告に対する「聞き取った内容の確認＋次のおすすめ」の返答文。
    private func confirmationText(_ result: DraftDictationSession.IngestResult,
                                  recommendation: Recommendation) -> String {
        var parts: [String] = []
        if result.mapChanged, let map = dictation.map {
            parts.append("ステージは\(map.nameJa ?? map.name)、モードは\(map.modeJa)ですね。")
        } else if result.modeChanged, let modeJa = dictation.modeJa {
            parts.append("モードは\(modeJa)ですね。")
        }
        if !result.addedBans.isEmpty {
            parts.append("BAN、" + result.addedBans.map { $0.nameJa ?? $0.name }.joined(separator: "、") + "ですね。")
        }
        if !result.addedAllies.isEmpty {
            parts.append("味方、" + result.addedAllies.map { $0.nameJa ?? $0.name }.joined(separator: "、") + "ですね。")
        }
        if !result.addedEnemies.isEmpty {
            parts.append("相手、" + result.addedEnemies.map { $0.nameJa ?? $0.name }.joined(separator: "、") + "ですね。")
        }
        if recommendation.phase == .complete {
            parts.append("ドラフト完了です。お疲れ様でした。")
        } else if let top = recommendation.advices.first {
            let reason = top.reason.isEmpty ? "" : "理由は、\(top.reason.replacingOccurrences(of: " / ", with: "、"))。"
            parts.append("次のおすすめは、\(top.nameJa ?? top.name)です。\(reason)")
        }
        return parts.joined(separator: " ")
    }

    private func speak(_ text: String, completion: @escaping () -> Void) {
        state = .speaking
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            // 読めなくても会話のループ自体は続ける
        }
        speakCompletion = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceCatalog.japanese
        utterance.rate = Float(AppSettings.speechRate)
        utterance.pitchMultiplier = 1.05
        synthesizer.speak(utterance)
    }

    // MARK: - ライフサイクル

    @objc private func handleBackground() {
        // 他アプリ（ブロスタ本体など）に切り替わったら、聞き続けられないので素直に止める。
        stop()
    }

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
        stop()
    }
}

extension VoiceAssistant: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let completion = self.speakCompletion
            self.speakCompletion = nil
            completion?()
        }
    }
}

/// アクター分離の外（オーディオスレッド）で完結させるための素の RMS 計算。
private func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData?[0] else { return 0 }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<frames { sum += data[i] * data[i] }
    return (sum / Float(frames)).squareRoot()
}
