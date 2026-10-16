import Foundation

/// ガチバトルのランク（ブロンズⅠ〜プロの 22 段階）。
/// 0 = 未設定、1 = ブロンズⅠ … 21 = マスターⅢ、22 = プロ。
/// 画像（アイコン）は App/BrawlUI.swift の拡張側。ここは文字だけ扱うので Mac のテストからも使える。
enum RankTier {
    static let count = 22
    private static let groups = ["ブロンズ", "シルバー", "ゴールド", "ダイヤモンド", "ミシック", "レジェンド", "マスター"]
    private static let numerals = ["Ⅰ", "Ⅱ", "Ⅲ"]

    static func label(_ tier: Int) -> String {
        guard (1...count).contains(tier) else { return "未設定" }
        if tier == count { return "プロ" }
        return groups[(tier - 1) / 3] + numerals[(tier - 1) % 3]
    }

    /// OCR で読んだ文字（「マスターⅡ」「Masters II」「レジェンド3」など）からランクを推定する。
    static func parse(_ text: String) -> Int? {
        let t = text.replacingOccurrences(of: " ", with: "").uppercased()
        if (t.contains("プロ") && !t.contains("プロフィール")) || t == "PRO" { return count }
        let english = ["BRONZE", "SILVER", "GOLD", "DIAMOND", "MYTHIC", "LEGENDARY", "MASTER"]
        var group: Int?
        for (i, name) in groups.enumerated() where t.contains(name) { group = i }
        if group == nil {
            for (i, name) in english.enumerated() where t.contains(name) { group = i }
        }
        guard let group else { return nil }
        var level = 1
        if t.contains("Ⅲ") || t.contains("III") || t.hasSuffix("3") { level = 3 }
        else if t.contains("Ⅱ") || t.contains("II") || t.hasSuffix("2") { level = 2 }
        return group * 3 + level
    }
}
