import MetalKit
import SwiftUI

/// 宇宙演出の状態。対話モードの状態に対応する。
enum CosmosMode: Equatable {
    /// 待機中。ときどき自分から「ひび → 破裂 → 再生」を繰り返す
    case idle
    /// 聞いている。声が大きいほど強く吸い込み、割れ目から光が漏れる
    case listening
    /// 考え中。球が破片に分裂して宙に浮く
    case thinking
    /// 答えている。入った瞬間に破裂し、再生してから声に合わせて脈打つ
    case speaking
}

/// 宇宙の背景＋光る球体を GPU で描く。SwiftUI からは普通の View として置くだけ。
///
/// CPU は 1 フレームに数十バイトの uniform を渡すだけなので、SwiftUI の再描画や
/// メインスレッドの処理を一切圧迫しない（以前の Canvas 実装で固まった反省から）。
struct CosmosView: UIViewRepresentable {
    var mode: CosmosMode = .idle
    /// 球の中心（画面に対する 0〜1）
    var center: CGPoint = CGPoint(x: 0.5, y: 0.4)
    /// 球の半径（画面の短辺に対する比）
    var radius: CGFloat = 0.2
    /// 声の大きさ（0〜1）を毎フレーム取りに行く。nil なら 0。
    var level: (() -> Float)? = nil
    var framesPerSecond = 60
    /// 画面が隠れている間は止めて電池を節約する
    var isPaused = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: CosmosRenderer?
    }

    func makeUIView(context: Context) -> MTKView {
        let view = CosmosMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.backgroundColor = UIColor(red: 0.01, green: 0.014, blue: 0.04, alpha: 1)
        view.clearColor = MTLClearColor(red: 0.01, green: 0.014, blue: 0.04, alpha: 1)
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = framesPerSecond
        if let renderer = CosmosRenderer(view: view) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        apply(to: context.coordinator.renderer)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        if view.isPaused != isPaused { view.isPaused = isPaused }
        apply(to: context.coordinator.renderer)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
    }

    private func apply(to renderer: CosmosRenderer?) {
        guard let renderer else { return }
        renderer.setMode(mode)
        renderer.center = SIMD2(Float(center.x), Float(center.y))
        renderer.radius = Float(radius)
        renderer.levelProvider = level
    }
}

/// 描画解像度を「画面の大きさに関係なくほぼ一定の画素数」に抑える MTKView。
/// iPad の大画面でも GPU 負荷が iPhone と同程度で済むようにする（光の表現は多少粗くても目立たない）。
final class CosmosMTKView: MTKView {
    private static let targetPixels: CGFloat = 820_000

    override func layoutSubviews() {
        let area = max(bounds.width * bounds.height, 1)
        let scale = min(window?.screen.nativeScale ?? 2, max(0.75, (Self.targetPixels / area).squareRoot()))
        if abs(contentScaleFactor - scale) > 0.01 { contentScaleFactor = scale }
        super.layoutSubviews()
    }
}

/// 時間の積分と状態遷移（吸い込み → ひび → 破裂 → 再生）だけを受け持つ。描画は全部シェーダー。
final class CosmosRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var a: SIMD4<Float>
        var b: SIMD4<Float>
        var c: SIMD4<Float>
        var d: SIMD4<Float>
    }

    private enum Phase { case calm, charge, burst, reform }

    var center = SIMD2<Float>(0.5, 0.4)
    var radius: Float = 0.2
    var levelProvider: (() -> Float)?

    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var streakParams = CosmosShader.streakParams

    private var mode: CosmosMode = .idle
    private var phase: Phase = .calm
    private var phaseTime: Float = 0
    private var calmDuration: Float = 6.5
    private var lastTimestamp: CFTimeInterval?
    private var time: Float = 0

    // 毎フレームなめらかに追従させる値
    private var energy: Float = 0.25
    private var absorb: Float = 0.35
    private var crack: Float = 0
    private var split: Float = 0
    private var shock: Float = -1
    private var flash: Float = 0
    private var reform: Float = 1
    private var level: Float = 0
    private var swirlPhase: Float = 0
    private var flowPhase: Float = 0

    init?(view: MTKView) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        super.init()
        let pixelFormat = view.colorPixelFormat
        // シェーダーのコンパイル（数十〜百数十 ms）は画面遷移を止めないよう裏で行う。
        // 終わるまでは clearColor の夜空色だけが出る。
        device.makeLibrary(source: CosmosShader.source, options: nil) { [weak self] library, error in
            guard let library,
                  let vertex = library.makeFunction(name: "cosmos_vertex"),
                  let fragment = library.makeFunction(name: "cosmos_fragment") else {
                if let error { print("CosmosShader compile error: \(error)") }
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            desc.colorAttachments[0].pixelFormat = pixelFormat
            let state = try? device.makeRenderPipelineState(descriptor: desc)
            DispatchQueue.main.async { self?.pipeline = state }
        }
    }

    func setMode(_ newMode: CosmosMode) {
        guard newMode != mode else { return }
        let old = mode
        mode = newMode
        if newMode == .speaking && old != .speaking && phase == .calm {
            startBurst()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - (lastTimestamp ?? now), 0), 0.1))
        lastTimestamp = now
        step(dt)

        guard let pipeline,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        var u = Uniforms(
            a: [time, swirlPhase, energy, flowPhase],
            b: [crack, split, shock, flash],
            c: [center.x, center.y, radius, reform],
            d: [Float(size.width), Float(size.height), level, absorb]
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&streakParams,
                                 length: MemoryLayout<SIMD4<Float>>.stride * streakParams.count,
                                 index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: - 状態遷移

    private func startBurst() {
        phase = .burst
        phaseTime = 0
    }

    private func step(_ dt: Float) {
        time += dt
        if time > 3000 { time -= 3000 }   // float の精度を保つ（見た目が飛ばない程度の周期）
        phaseTime += dt

        let rawLevel = min(1, max(0, levelProvider?() ?? 0))
        level += (rawLevel - level) * min(1, dt * (rawLevel > level ? 18 : 5))

        var energyTarget: Float = 0.25
        var absorbTarget: Float = 0.35
        var crackTarget: Float = 0
        var splitTarget: Float = 0

        switch phase {
        case .charge:
            let p = min(phaseTime / 1.3, 1)
            crackTarget = p
            absorbTarget = 0.6 + 1.6 * p
            energyTarget = 0.4 + 0.6 * p
            if p >= 1 { startBurst() }

        case .burst:
            let p = min(phaseTime / 1.1, 1)
            split = 0.05 + 1.6 * (1 - pow(1 - p, 3))
            shock = p
            flash = max(0, 1 - p * 2.4)
            crackTarget = 1 - p
            absorbTarget = -2.4            // 破片と一緒に粒子も外へ吹き飛ぶ
            energyTarget = 1
            if p >= 1 {
                phase = .reform
                phaseTime = 0
                split = 0
                shock = -1
                reform = 0.1
            }

        case .reform:
            let p = min(phaseTime / 1.7, 1)
            reform = 0.1 + 0.9 * easeOutBack(p)
            absorbTarget = 2.0             // 散った光を一気に吸い戻して球が再生する
            energyTarget = 0.6
            if p >= 1 {
                phase = .calm
                phaseTime = 0
                reform = 1
                calmDuration = Float.random(in: 5.5...8.5)
            }

        case .calm:
            switch mode {
            case .idle:
                if phaseTime > calmDuration {
                    phase = .charge
                    phaseTime = 0
                }
            case .listening:
                absorbTarget = 0.7 + 2.4 * level
                energyTarget = 0.45 + 0.8 * level
                crackTarget = max(0, level - 0.3) * 1.3
            case .thinking:
                crackTarget = 1
                splitTarget = 0.14 + 0.05 * sin(time * 2.2)
                absorbTarget = 1.0
                energyTarget = 0.6
            case .speaking:
                energyTarget = 0.65 + 0.3 * (0.5 + 0.5 * sin(time * 9))
                absorbTarget = 0.6
            }
        }

        let k = min(1, dt * 4)
        energy += (energyTarget - energy) * k
        absorb += (absorbTarget - absorb) * min(1, dt * (phase == .burst ? 10 : 3))
        if phase != .burst {
            crack += (crackTarget - crack) * k
            split += (splitTarget - split) * min(1, dt * 5)
            if split < 0.002 { split = 0 }
        }

        // 渦の回転と粒子の流れは「速度を積分した位相」で渡す（速度が変わっても位置が飛ばない）
        swirlPhase += dt * (0.35 + 0.55 * max(absorb, 0)) * (phase == .burst ? 2.5 : 1)
        flowPhase += dt * (0.25 + 0.9 * absorb)
    }

    private func easeOutBack(_ x: Float) -> Float {
        let c1: Float = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
