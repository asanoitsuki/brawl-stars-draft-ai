import CryptoKit
import Foundation

/// ElevenLabs Text-to-Speech API のごく薄いラッパー。
///
/// ドキュメント: https://elevenlabs.io/docs/api-reference/text-to-speech
/// API キーは AppSettings（端末内 UserDefaults）にのみ保存し、リポジトリには一切含めない。
enum CloudSpeechClient {
    enum SpeechError: LocalizedError {
        case notConfigured
        case invalidKey
        case rateLimited
        case server(Int, String)
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "ElevenLabs の API キーが未設定です"
            case .invalidKey: return "ElevenLabs の API キーが無効です（401）"
            case .rateLimited: return "ElevenLabs のレート制限に達しました（429）"
            case .server(let code, let body): return "ElevenLabs エラー \(code): \(body.prefix(200))"
            case .network(let e): return "通信エラー: \(e.localizedDescription)"
            }
        }
    }

    /// 1 フレーズを音声合成する。返り値は MP3 バイト列。
    static func synthesize(text: String) async throws -> Data {
        guard AppSettings.isElevenLabsConfigured else { throw SpeechError.notConfigured }
        let voiceID = AppSettings.elevenLabsVoiceID
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(AppSettings.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": AppSettings.elevenLabsModelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpeechError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw SpeechError.server(0, "no response") }
        switch http.statusCode {
        case 200: return data
        case 401: throw SpeechError.invalidKey
        case 429: throw SpeechError.rateLimited
        default:
            throw SpeechError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// キャッシュキー（テキスト＋声＋モデルのハッシュ）。ボイス変更や声色設定を変えたら
    /// 自動的に別キャッシュになるようにする。
    static func cacheKey(for text: String) -> String {
        let raw = "\(text)|\(AppSettings.elevenLabsVoiceID)|\(AppSettings.elevenLabsModelID)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
