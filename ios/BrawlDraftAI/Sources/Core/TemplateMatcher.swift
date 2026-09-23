import Accelerate
import Foundation

/// テンプレート 1 件ぶんの照合結果。
struct MatchResult {
    let index: Int
    let id: Int
    let name: String
    /// 0〜1。1 に近いほど一致。
    let score: Float
    /// 2 位との差。小さいときは「似たキャラと紛らわしい」ので信頼度を下げる。
    let margin: Float

    var isConfident: Bool { score >= TemplateMatcher.acceptScore && margin >= TemplateMatcher.acceptMargin }
}

/// 正規化相互相関（NCC）によるテンプレートマッチング。
///
/// 記述子は平均 0・ノルム 1 に正規化済みなので、内積がそのまま相関係数になる。
/// 全テンプレートを 1 本の連続バッファに詰めて `vDSP_dotpr` を回すので、
/// 110 件 × 256 次元でも数十マイクロ秒で終わる。
final class TemplateMatcher {
    static let acceptScore: Float = 0.62
    static let acceptMargin: Float = 0.035

    /// 輝度と色の配合比。色は端末のカラープロファイル差で揺れるので輝度を主にする。
    static let grayWeight: Float = 0.78
    static let colorWeight: Float = 0.22

    private let grayDim: Int
    private let colorDim: Int
    private let grayFlat: [Float]
    private let colorFlat: [Float]
    private let hashes: [UInt64]
    let ids: [Int]
    let names: [String]

    var count: Int { ids.count }

    init(grayDim: Int, colorDim: Int,
         gray: [[Float]], color: [[Float]], hashes: [UInt64],
         ids: [Int], names: [String]) {
        self.grayDim = grayDim
        self.colorDim = colorDim
        self.grayFlat = gray.flatMap { $0 }
        self.colorFlat = color.flatMap { $0 }
        self.hashes = hashes
        self.ids = ids
        self.names = names
    }

    /// 記述子に最も近いテンプレートを返す。
    /// - Parameter excluding: すでに使われた ID（同じキャラが 2 回出ることはない）
    func best(for descriptor: Descriptor, excluding: Set<Int> = []) -> MatchResult? {
        guard count > 0, descriptor.gray.count == grayDim, descriptor.color.count == colorDim else {
            return nil
        }

        var bestIndex = -1
        var bestScore = -Float.greatestFiniteMagnitude
        var secondScore = -Float.greatestFiniteMagnitude

        descriptor.gray.withUnsafeBufferPointer { q in
            descriptor.color.withUnsafeBufferPointer { qc in
                grayFlat.withUnsafeBufferPointer { g in
                    colorFlat.withUnsafeBufferPointer { c in
                        for i in 0..<ids.count {
                            if excluding.contains(ids[i]) { continue }
                            var gs: Float = 0
                            vDSP_dotpr(q.baseAddress!, 1,
                                       g.baseAddress! + i * grayDim, 1,
                                       &gs, vDSP_Length(grayDim))
                            var cs: Float = 0
                            vDSP_dotpr(qc.baseAddress!, 1,
                                       c.baseAddress! + i * colorDim, 1,
                                       &cs, vDSP_Length(colorDim))
                            let score = TemplateMatcher.grayWeight * gs + TemplateMatcher.colorWeight * cs
                            if score > bestScore {
                                secondScore = bestScore
                                bestScore = score
                                bestIndex = i
                            } else if score > secondScore {
                                secondScore = score
                            }
                        }
                    }
                }
            }
        }

        guard bestIndex >= 0 else { return nil }
        let margin = secondScore == -Float.greatestFiniteMagnitude ? bestScore : bestScore - secondScore
        return MatchResult(index: bestIndex, id: ids[bestIndex], name: names[bestIndex],
                           score: bestScore, margin: margin)
    }

    /// dHash のハミング距離。デバッグ表示用。
    func hammingDistance(_ descriptor: Descriptor, at index: Int) -> Int {
        (hashes[index] ^ descriptor.dhash).nonzeroBitCount
    }
}
