import Foundation

/// キャラ名・立ち回りアドバイス・固定フレーズは語彙が閉じているので、
/// 対戦前にまとめて ElevenLabs で合成してキャッシュしておける。
/// これをやっておくと、本番中は「理由」「立ち回り」の動的な文以外はネット無しで即再生になる。
enum SpeechPrecacher {
    struct Progress {
        var done: Int
        var total: Int
        var failed: Int = 0
        var currentText: String = ""
    }

    /// 事前キャッシュ対象の全フレーズ。
    static func vocabulary(rules: LoadedRules) -> [String] {
        var texts: Set<String> = []
        for b in rules.document.brawlers {
            texts.insert(b.nameJa ?? b.name)
        }
        for tip in rules.document.roleTips.values {
            texts.insert(tip)
        }
        // Recommender.swift が組み立てる固定フレーズ（ブラインドピック / 将来の draftPick 両方）
        texts.formUnion([
            "おすすめ、", "次点、", "自チーム選択完了。", "候補が見つかりません",
            "バン推奨、", "初手、", "ラスト、", "完了、",
            "テスト。ラスト、", "パイパー。",
        ])
        for n in 2...5 { texts.insert("\(n)手目、") }
        return texts.sorted()
    }

    /// 未キャッシュぶんだけを、控えめな並列数で合成していく。
    /// 呼び出し側は Task 内から await して、onProgress で進捗バーを更新すればよい。
    static func run(rules: LoadedRules, concurrency: Int = 3,
                    onProgress: @escaping (Progress) -> Void) async {
        let all = vocabulary(rules: rules)
        let pending = all.filter { SpeechCache.cachedFile(for: $0) == nil }
        let total = all.count
        var done = total - pending.count
        var failed = 0
        onProgress(Progress(done: done, total: total, currentText: ""))

        guard !pending.isEmpty else { return }

        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = pending.makeIterator()
            var active = 0

            func addNext() {
                guard let text = iterator.next() else { return }
                active += 1
                group.addTask {
                    do {
                        _ = try await SpeechCache.fileURL(for: text)
                        return (text, true)
                    } catch {
                        return (text, false)
                    }
                }
            }
            for _ in 0..<concurrency { addNext() }

            while let (text, ok) = await group.next() {
                active -= 1
                done += 1
                if !ok { failed += 1 }
                onProgress(Progress(done: done, total: total, failed: failed, currentText: text))
                addNext()
                _ = active
            }
        }
    }
}
