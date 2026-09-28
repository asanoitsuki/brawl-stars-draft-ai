import Foundation

/// ゲーム実況・YouTuber風の一言コメントを、1 位候補の自信度に応じてランダムに添える。
///
/// ブラインドピック段階では相手構成が見えないので、コメントは「この一手の強さ」についてで、
/// 「相手のピックが弱い」とは言えない（見えていないため）。エリート帯以降（BAN・相手公開）に
/// 対応したら、相手構成を踏まえたコメントも同じ仕組みで足せる。
enum HypeCommentary {
    enum Tier {
        /// 他候補との差が大きい、または勝率が明確に良い
        case confident
        /// 普通〜無難
        case normal
        /// 僅差・勝率が微妙で賭けに近い
        case risky
    }

    private static let confidentLines = [
        "これ選んだら普通に勝てるわ",
        "文句なしの一手",
        "相手目線だとかなりキツい構成やと思う",
        "ここで外す方が逆に難しいまである",
        "この構成、素直に強いから安心して置いてこ",
        "変に迷わずこれで通していい",
    ]

    private static let normalLines = [
        "無難に強い、迷ったらこれ",
        "変に冒険せず、これで固めていこ",
        "堅実な一手やね",
        "派手さはないけど腐らない選択",
        "とりあえずこれ置いとけば大崩れはしない",
    ]

    private static let riskyLines = [
        "正直きわどいけど、今の情報だとこれしかない",
        "ワンチャン狙いの一手やな",
        "きれいに勝つ画は見えんけど、他よりマシって感じ",
        "これで負けたらエリ止まり確定やろ、気合い入れて",
        "賭けの一手やから、立ち回りでカバーしてこ",
        "ここは正解が無いから、自信持って振り切ろう",
    ]

    /// advices は score 降順（呼び出し側でソート済み）を前提とする。
    static func comment(for advices: [PickAdvice]) -> String? {
        guard let top = advices.first else { return nil }
        let lines: [String]
        switch tier(top: top, second: advices.count > 1 ? advices[1] : nil) {
        case .confident: lines = confidentLines
        case .normal: lines = normalLines
        case .risky: lines = riskyLines
        }
        return lines.randomElement()
    }

    private static func tier(top: PickAdvice, second: PickAdvice?) -> Tier {
        if let wr = top.winRate {
            if wr >= 54 { return .confident }
            if wr <= 48 { return .risky }
            return .normal
        }
        guard let second else { return .confident }  // 候補が1つしかない = 他に選びようがない
        let scale = max(abs(top.score), 0.1)
        let relGap = (top.score - second.score) / scale
        if relGap >= 0.25 { return .confident }
        if relGap <= 0.05 { return .risky }
        return .normal
    }
}
