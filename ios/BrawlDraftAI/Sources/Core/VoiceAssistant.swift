import AVFoundation
import Foundation
import Speech
import UIKit

/// マイクで話しかけた内容を聞き取り→回答を声で返す、をこのアプリが前面にある間ずっと繰り返す。
///
/// iOS の制約上、ブロスタ本体が前面にある間はサードパーティアプリのマイクは使えない
/// （バックグラウンドでの常時マイク録音は OS レベルで禁止・審査でも通らない）。
/// そのため「対話モード」はこのアプリの画面を開いている間だけ会話できる、という設計にしてある。
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
    /// バッファは 1024 フレーム/44.1kHz ≒ 23ms なので、40 バッファ ≒ 0.9 秒の無音で確定させる。
    private func registerAudioLevel(_ level: Float) {
        guard state == .listening else { return }
        let isQuiet = level < 0.015
        if isQuiet {
            guard hasHeardSpeech else { return }
            quietBufferCount += 1
            if quietBufferCount > 40 {
                quietBufferCount = 0
                request?.endAudio()
            }
        } else {
            quietBufferCount = 0
        }
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
        let answer = AssistantIntentEngine.answer(to: heard)
        turns.append(Turn(question: heard, answer: answer.text))
        if turns.count > 30 { turns.removeFirst(turns.count - 30) }

        if answer.shouldStop {
            speak(answer.text) { [weak self] in self?.stop() }
        } else {
            speak(answer.text) { [weak self] in
                guard let self, self.running else { return }
                self.beginListening()
            }
        }
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
