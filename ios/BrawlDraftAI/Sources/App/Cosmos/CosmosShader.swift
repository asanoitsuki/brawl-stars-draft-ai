import Foundation

/// 対話モードの宇宙演出（光る球体・渦を巻く光の筋・吸い込まれる粒子・分裂・破裂）を
/// 1 枚のフラグメントシェーダーで描く。
///
/// ビルド時ではなく **実行時に** `MTLDevice.makeLibrary(source:)` でコンパイルする。
/// Xcode 26 以降は .metal ファイルのビルドに別ダウンロードの Metal Toolchain が要るため、
/// ソース文字列で持っておけば追加インストール無しでどの Mac からでもビルドできる。
///
/// CPU 側（CosmosRenderer）は時間の積分と状態遷移だけを受け持ち、
/// 1 フレームあたりの仕事は uniform 64 バイトを渡すことだけ。描画はすべて GPU。
enum CosmosShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 a;   // x: 時間  y: 渦の位相(積分)  z: エネルギー  w: 流入の位相(積分)
    float4 b;   // x: ひび  y: 分裂量  z: 衝撃波の進行(0..1, 負=なし)  w: 閃光
    float4 c;   // xy: 中心(0..1)  z: 半径(短辺比)  w: 再生成スケール
    float4 d;   // xy: 解像度(px)  z: 声の大きさ  w: 吸い込みの強さ
};

struct VOut { float4 pos [[position]]; };

vertex VOut cosmos_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

constant float PI  = 3.14159265;
constant float TAU = 6.2831853;
constant int SECTORS = 9;
constant int STREAKS = 18;

static float hash21(float2 p) {
    p = fract(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return fract(p.x * p.y);
}
static float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n * 31.7 + 11.3));
}
static float hash11(float n) { return fract(sin(n * 91.345 + 0.17) * 47453.5453); }

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 4; i++) { v += amp * vnoise(p); p = p * 2.03 + 17.1; amp *= 0.5; }
    return v;
}
static float wrapAngle(float a) { return a - TAU * floor(a / TAU); }

// 星（グリッドごとに 1 個、密度で間引き）
static float3 starLayer(float2 p, float scale, float t, float density) {
    float2 g = p * scale;
    float2 id = floor(g);
    float h = hash21(id);
    if (h > density) return float3(0.0);
    float2 off = hash22(id + 3.1) - 0.5;
    float2 dv = (fract(g) - 0.5 - off * 0.7) / scale;
    float dp = length(dv);
    float size = mix(0.0008, 0.0024, pow(hash21(id + 7.7), 3.0));
    float tw = 0.6 + 0.4 * sin(t * (0.8 + 2.6 * hash21(id + 1.3)) + h * 40.0);
    float core = exp(-(dp * dp) / (size * size));
    float glow = exp(-dp / (size * 3.5)) * 0.10;
    float3 tint = mix(float3(0.62, 0.76, 1.0), float3(1.0, 0.86, 0.96), hash21(id + 5.5));
    return tint * (core + glow) * tw;
}

// 球面（中心 0・半径 R）。都市の灯りのような光点が回る地球儀風の質感。
static float3 shadeSphere(float2 q, float R, float t, float energy) {
    float d = length(q);
    if (d >= R) return float3(0.0);
    float2 n2 = q / R;
    float z = sqrt(max(0.0, 1.0 - dot(n2, n2)));
    float3 n = float3(n2, z);
    float fres = pow(1.0 - z, 2.4);

    float ang = t * 0.16;
    float ca = cos(ang), sa = sin(ang);
    float3 r = float3(n.x * ca + n.z * sa, n.y, -n.x * sa + n.z * ca);
    float tl = 0.38, ct = cos(tl), st = sin(tl);
    r = float3(r.x, r.y * ct - r.z * st, r.y * st + r.z * ct);
    float lon = atan2(r.x, r.z);
    float lat = asin(clamp(r.y, -1.0, 1.0));
    float2 sph = float2(lon / PI, lat / (PI * 0.5));

    float3 col = float3(0.020, 0.045, 0.17) + float3(0.22, 0.42, 1.0) * pow(1.0 - z, 1.4) * 0.55;
    float land = fbm(sph * float2(3.2, 2.1) + 4.0);
    float landMask = smoothstep(0.48, 0.72, land);
    col += float3(0.20, 0.38, 0.95) * landMask * 0.22;

    // 光点（陸地ほど多い）
    float2 g = sph * float2(36.0, 18.0);
    float2 id = floor(g);
    float2 o = 0.15 + 0.7 * hash22(id + 2.2);
    float dd = length(fract(g) - o);
    float hl = hash21(id + 9.1);
    float on = step(0.55 - 0.35 * landMask, hl) * (0.55 + 0.45 * sin(t * (1.2 + 3.0 * hl) + hl * 30.0));
    float3 lightCol = mix(float3(0.72, 0.86, 1.0), float3(1.0, 0.62, 0.95), step(0.82, hash21(id + 4.4)));
    col += lightCol * (exp(-dd * dd * 80.0) * 2.0 + exp(-dd * 7.0) * 0.10) * on * (0.45 + 0.55 * z);

    // 細かいきらめき
    float2 g2 = sph * float2(80.0, 40.0);
    float2 id2 = floor(g2);
    float dd2 = length(fract(g2) - 0.5 - (hash22(id2) - 0.5) * 0.6);
    col += float3(0.8, 0.9, 1.0) * exp(-dd2 * dd2 * 120.0) * step(0.80, hash21(id2 + 1.7)) * 0.7 * z;

    col += float3(0.42, 0.62, 1.0) * pow(z, 3.0) * 0.08;
    col += float3(0.55, 0.86, 1.0) * fres * (1.6 + 1.0 * energy);
    // 縁のくっきりした光の輪
    float rimD = (d - R * 0.975) / (R * 0.02);
    col += float3(0.80, 0.95, 1.0) * exp(-rimD * rimD) * (1.3 + 0.8 * energy);
    float edge = smoothstep(R, R - 0.0025, d);
    return col * edge;
}

// 割れ目の角度（半径によって少しギザギザさせる）
static float crackAngle(int j, float rr) {
    int jj = j % SECTORS;
    float fj = float(jj);
    float base = (fj + 0.42 * (hash11(fj + 3.0) - 0.5)) / float(SECTORS) * TAU;
    return base + float(j / SECTORS) * TAU + 0.07 * sin(rr * 9.0 + fj * 1.7) + 0.03 * sin(rr * 23.0 + fj);
}

static float segDist(float2 p, float2 a, float2 b, thread float &h) {
    float2 pa = p - a, ba = b - a;
    h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

// 中心へ渦を巻いて吸い込まれる粒子（対数極座標のグリッドを流す）
static float3 inflowLayer(float2 p, float d, float R, float flow, float cells, float swirl, float seed) {
    float lr = log(max(d, 1e-4));
    float a = atan2(p.y, p.x);
    float2 g = float2(lr * cells * 0.5 + flow, (a / TAU) * cells + lr * swirl);
    float2 id = floor(g);
    id.y = id.y - cells * floor(id.y / cells);   // 角度方向の継ぎ目を消す
    float2 f = fract(g);
    float h = hash21(id + seed);
    if (h > 0.34) return float3(0.0);
    float2 o = 0.2 + 0.6 * hash22(id + seed + 5.0);
    float2 df = (f - o) * float2(0.45, 2.6);      // 半径方向に伸ばして流れて見せる
    float b = exp(-dot(df, df) * 160.0);
    float fadeIn = 1.0 - smoothstep(R * 2.0, R * 3.6, d);
    float fadeOut = smoothstep(R * 0.96, R * 1.12, d);
    float3 c = mix(float3(0.55, 0.85, 1.0), float3(0.92, 0.62, 1.0), hash21(id + seed + 9.0));
    return c * b * fadeIn * fadeOut * (0.5 + 0.9 * hash21(id + 2.0));
}

fragment float4 cosmos_fragment(VOut in [[stage_in]], constant Uniforms &U [[buffer(0)]],
                                constant float4 *S [[buffer(1)]]) {
    float t = U.a.x, swirl = U.a.y, energy = U.a.z, flow = U.a.w;
    float crack = U.b.x, split = U.b.y, shock = U.b.z, flash = U.b.w;
    float R = U.c.z, reform = U.c.w;
    float2 res = U.d.xy;
    float level = U.d.z, absorb = U.d.w;

    float minDim = min(res.x, res.y);
    float2 center = U.c.xy * res;
    float2 p = (in.pos.xy - center) / minDim;
    float d = length(p);
    float Rr = R * reform;
    float2 uv = in.pos.xy / res;

    // ---- 背景（深い紺と紫の星雲）----
    float3 col = mix(float3(0.008, 0.012, 0.036), float3(0.018, 0.016, 0.062), uv.y);
    float neb = fbm(p * 1.5 + float2(t * 0.010, -t * 0.006));
    float neb2 = fbm(p * 3.0 + float2(-t * 0.012, t * 0.004) + 7.0);
    col += float3(0.11, 0.05, 0.24) * smoothstep(0.38, 0.92, neb) * 0.50;
    col += float3(0.02, 0.08, 0.22) * smoothstep(0.48, 0.96, neb2) * 0.45;

    // ---- 星（中心の近くは重力レンズで歪み、穴に飲まれて消える）----
    float lens = 0.010 * (0.6 + max(absorb, 0.0));
    float2 ps = p - (p / max(d, 1e-4)) * lens / (d + 0.06);
    ps += float2(t * 0.0025, t * 0.0012);
    float3 stars = starLayer(ps, 30.0, t, 0.40) * 0.95
                 + starLayer(ps + 3.7, 62.0, t * 1.3, 0.32) * 0.60
                 + starLayer(ps + 9.1, 125.0, t * 0.7, 0.26) * 0.38;
    col += stars * smoothstep(R * 0.95, R * 1.9, d);

    // ---- 球のまわりの光暈 ----
    float ed = max(d - Rr, 0.0);
    col += float3(0.36, 0.68, 1.0) * exp(-ed * 13.0) * (0.45 + 0.65 * energy) * reform;
    col += float3(0.42, 0.34, 1.0) * exp(-ed * 4.0) * (0.07 + 0.10 * energy);

    // ---- 渦を巻く光の筋（筋ごとに傾きの違う円盤上のらせん。交差して磁力線のように見える）----
    // パラメータは CPU 側（CosmosRenderer.streakParams）で前計算して渡す。1 本 3 × float4:
    //   S[3k]   = (基準半径(R倍), 長さ(rad), 巻き込み率, 回転速度倍率)
    //   S[3k+1] = (太さ, 濃淡の周波数, 色(0=水色..1=紫), 明るさ)
    //   S[3k+2] = (cos 傾き, sin 傾き, 1/扁平率, 初期位相)
    float3 front = float3(0.0), back = float3(0.0);
    for (int k = 0; k < STREAKS; k++) {
        float4 s0 = S[3 * k], s1 = S[3 * k + 1], s2 = S[3 * k + 2];
        float2 q = float2(p.x * s2.x - p.y * s2.y, p.x * s2.y + p.y * s2.x);
        q.y *= s2.z;
        float qr = length(q);
        float baseR = R * s0.x;
        if (qr > baseR * 1.08 || qr < Rr * 0.6) continue;
        float qa = atan2(q.y, q.x);
        float phi = wrapAngle(qa - (s2.w + swirl * s0.w));
        float span = s0.y;
        if (phi > span) continue;
        float rk = baseR * exp(-phi * s0.z);
        float w = s1.x * (1.0 + 0.5 * energy);
        float along = smoothstep(0.0, 1.2, phi) * (1.0 - smoothstep(span - 0.7, span, phi));
        float dash = 0.62 + 0.38 * sin(phi * s1.y - flow * 2.0 + float(k) * 1.3);
        float3 c = mix(float3(0.42, 0.82, 1.0), float3(0.66, 0.48, 1.0), s1.z);
        float amp = s1.w * along * dash;
        float3 contrib = float3(0.0);
        for (int j = 0; j < 2; j++) {
            float rj = rk * (1.0 + (float(j) - 0.5) * 0.026);
            float dist = abs(qr - rj);
            float line = exp(-(dist * dist) / (w * w)) + 0.10 * exp(-dist / (w * 6.0));
            contrib += c * line * amp;
        }
        if (q.y > 0.0) front += contrib; else back += contrib;
    }

    // ---- 球（無傷 / ひび / 分裂・破片）----
    float3 sphereCol = float3(0.0);
    float cover = 0.0;
    if (split < 0.002) {
        sphereCol = shadeSphere(p, Rr, t, energy);
        cover = smoothstep(Rr, Rr - 0.003, d);
        if (crack > 0.001 && d < Rr) {
            float a = atan2(p.y, p.x);
            float best = 1e3;
            for (int j = 0; j < SECTORS; j++) {
                float da = abs(wrapAngle(a - crackAngle(j, d / Rr) + PI) - PI);
                best = min(best, da * d);
            }
            float ringR = Rr * (0.55 + 0.06 * sin(a * 7.0));
            best = min(best, abs(d - ringR));
            float grow = smoothstep(0.0, 1.0, crack * 1.4 - (1.0 - d / Rr) * 0.4);
            sphereCol += float3(0.70, 0.92, 1.0) * (exp(-best / 0.0022) * 2.2 + exp(-best / 0.018) * 0.35) * grow;
        }
    } else {
        float fade = 1.0 - smoothstep(0.75, 1.45, split);
        for (int j = 0; j < SECTORS; j++) {
            for (int i = 0; i < 2; i++) {
                float fj = float(j), fi = float(i);
                float hs = hash11(fj * 7.0 + fi * 13.0 + 1.0);
                float midA = 0.5 * (crackAngle(j, 0.7) + crackAngle(j + 1, 0.7));
                float2 dir = float2(cos(midA), sin(midA));
                float dist = split * Rr * (0.30 + 0.95 * hs) * (1.0 + fi * 0.9);
                float rot = split * (hs - 0.5) * 1.3;
                float2 centroid = dir * Rr * (i == 0 ? 0.32 : 0.78);
                float2 qq = p - dir * dist - centroid;
                float cr = cos(-rot), sr = sin(-rot);
                qq = centroid + float2(qq.x * cr - qq.y * sr, qq.x * sr + qq.y * cr);
                float qd = length(qq);
                if (qd >= Rr) continue;
                float qang = atan2(qq.y, qq.x);
                float a0 = crackAngle(j, qd / Rr), a1 = crackAngle(j + 1, qd / Rr);
                float width = a1 - a0;
                float rel = wrapAngle(qang - a0);
                if (rel >= width) continue;
                float ringR = Rr * (0.55 + 0.06 * sin(qang * 7.0));
                bool inner = qd < ringR;
                if ((i == 0) != inner) continue;
                float3 sc = shadeSphere(qq, Rr, t, energy);
                float edgeD = min(rel, width - rel) * qd;
                edgeD = min(edgeD, abs(qd - ringR));
                if (i == 1) edgeD = min(edgeD, Rr - qd);
                sc += float3(0.65, 0.9, 1.0) * exp(-edgeD / 0.0035) * 1.6;
                sphereCol += sc * fade;
                cover = max(cover, fade);
            }
        }
    }

    // 割れ目から漏れる芯の光
    float core = exp(-d / (R * 0.22)) * (0.25 * energy + 0.9 * crack + 1.6 * min(split, 1.0));
    float3 coreCol = float3(0.75, 0.88, 1.0) * core;

    col = col * (1.0 - cover * 0.88);
    col += back * (1.0 - cover * 0.9);
    col += sphereCol;
    col += coreCol;
    col += front;

    // ---- 吸い込まれる粒子（破裂の瞬間だけ外へ飛ぶ）----
    col += inflowLayer(p, d, R, flow, 30.0, 2.2, 0.0) * 1.5;
    col += inflowLayer(p, d, R, flow * 1.35 + 3.0, 56.0, 3.4, 17.0) * 0.8;

    // ---- 流れ星（ときどき外から飛んできて中心に落ちる）----
    for (int m = 0; m < 3; m++) {
        float fm = float(m);
        float period = 4.5 + 3.5 * hash11(fm + 80.0);
        float cyc = t / period + hash11(fm + 90.0);
        float cycle = floor(cyc);
        float tt = fract(cyc);
        if (tt > 0.24) continue;
        float s = tt / 0.24;
        float a0 = hash11(cycle * 3.7 + fm * 11.0) * TAU;
        float2 startP = float2(cos(a0), sin(a0)) * 1.25;
        float bend = 0.7 * (hash11(cycle + fm) - 0.5);
        float e = s * s;
        float ang1 = a0 + bend * e;
        float2 head = float2(cos(ang1), sin(ang1)) * mix(1.25, R * 0.95, e);
        float e0 = max(s - 0.10, 0.0); e0 = e0 * e0;
        float ang0 = a0 + bend * e0;
        float2 tail = float2(cos(ang0), sin(ang0)) * mix(1.25, R * 0.95, e0);
        float hseg;
        float sd = segDist(p, tail, head, hseg);
        float vis = smoothstep(0.0, 0.1, s) * (1.0 - smoothstep(0.85, 1.0, s));
        col += float3(0.8, 0.92, 1.0) * (exp(-(sd * sd) / (0.0022 * 0.0022)) * hseg * hseg * 1.4
                                         + exp(-length(p - head) / 0.006) * 0.6) * vis;
    }

    // ---- 衝撃波と閃光 ----
    if (shock >= 0.0 && shock <= 1.0) {
        float rs = R * (1.0 + 5.5 * shock);
        float wdt = 0.008 + 0.035 * shock;
        float ring = exp(-((d - rs) * (d - rs)) / (wdt * wdt)) * pow(1.0 - shock, 1.4);
        col += float3(0.55, 0.82, 1.0) * ring * 1.5;
        col += float3(0.7, 0.5, 1.0) * exp(-abs(d - rs * 0.82) / 0.02) * pow(1.0 - shock, 2.0) * 0.35;
    }
    col += float3(0.85, 0.92, 1.0) * flash * exp(-d * 7.0) * 1.6;
    col += float3(0.5, 0.8, 1.0) * level * exp(-ed * 9.0) * 0.35 * reform;

    // トーンマップ + 周辺減光
    col = 1.0 - exp(-col * 1.2);
    float vig = 1.0 - 0.35 * smoothstep(0.45, 1.05, length(uv - float2(0.5, 0.45)) * 1.25);
    col *= vig;
    return float4(col, 1.0);
}
"""#
}

extension CosmosShader {
    /// 光の筋 18 本ぶんのパラメータ（シェーダーの S[] と同じ並び）。毎回同じ見た目になるよう固定シード。
    static let streakParams: [SIMD4<Float>] = {
        var rng = SplitMix64(seed: 0xB1A5_7D0C)
        var out: [SIMD4<Float>] = []
        for k in 0..<18 {
            let h1 = rng.unit(), h2 = rng.unit(), h3 = rng.unit(), h4 = rng.unit()
            // 大半は基準面のまわりに集め、数本だけ大きく傾けて交差させる
            let big = k % 6 == 5
            let tilt = -0.40 + (big ? (rng.unit() - 0.5) * 1.3 : (rng.unit() - 0.5) * 0.30)
            let flatness = big ? 0.42 + 0.25 * rng.unit() : 0.26 + 0.12 * rng.unit()
            out.append([1.12 + 3.4 * h1 * h1,          // 基準半径
                        1.6 + 3.0 * h2,                // 長さ
                        0.14 + 0.26 * h3,              // 巻き込み率
                        0.55 + 0.70 * h4])             // 回転速度
            out.append([0.0016 + 0.0026 * rng.unit(),  // 太さ
                        4.0 + 7.0 * rng.unit(),        // 濃淡の周波数
                        h2,                            // 色
                        0.55 + 0.70 * h1])             // 明るさ
            out.append([cos(tilt), sin(tilt), 1 / flatness, rng.unit() * 6.2831853])
        }
        return out
    }()
}

/// 再現性のある軽量乱数（見た目を起動ごとに変えないため）。
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
