import AppKit
import MetalKit
import QuartzCore

/// Must match `Uniforms` in CRT.metal (float2s first so layouts agree).
struct CRTUniforms {
    var viewSize: SIMD2<Float> = .zero
    var contentSize: SIMD2<Float> = .zero
    var time: Float = 0
    var lines: Float = 360
    var hres: Float = 480
    var curvature: Float = 0.06
    var maskStrength: Float = 0.3
    var scanStrength: Float = 0.85
    var squeezeX: Float = 1
    var squeezeY: Float = 1
    var brightness: Float = 1
    var staticAmount: Float = 0
    var fill: Float = 0
    var contentLod: Float = 0
    var vhs: Float = 0
    var vhsDir: Float = 1
    var picBrightness: Float = 1
    var picSaturation: Float = 1
    var glow: Float = 0.14
    var grain: Float = 0.03
    var interlace: Float = 0
    var field: Float = 0
}

@MainActor
final class CRTRenderer: NSObject, MTKViewDelegate {
    enum Source { case bars, video, snow }
    enum TapeMode { case normal, paused, forward, rewind }
    private enum Power { case on, off, turningOn(CFTimeInterval), turningOff(CFTimeInterval) }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let persistPipeline: MTLRenderPipelineState
    /// Frame rendered by the CRT shader, then merged with `accum` by the persistence pass.
    private var curTexture: MTLTexture?
    private var accum: [MTLTexture] = []
    private var accumIndex = 0
    private var resetAccum = true
    private var frameIndex = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var lastCommandBuffer: MTLCommandBuffer?
    private let contentSampler: MTLSamplerState
    private let osdSampler: MTLSamplerState
    private let barsTexture: MTLTexture
    private let blackTexture: MTLTexture
    private let osdTexture: MTLTexture
    private var videoTexture: MTLTexture?
    private var videoNeedsMips = false
    private let osdContext: CGContext
    private var lastOSD: OSDState?
    private var power: Power = .on
    private var staticUntil: CFTimeInterval = 0
    private let startTime = CACurrentMediaTime()

    var sink: VideoSink?
    var tapeMode: TapeMode = .normal
    var picBrightness: Float = 1
    var picSaturation: Float = 1
    private var vhsLevel: Float = 0
    private var glitchUntil: CFTimeInterval = 0
    var source: Source = .bars
    /// Display aspect of the video (0 = use frame dimensions).
    var videoAspect: Double = 0
    /// 0 = auto: ~3 physical pixels per scanline so lines stay visible on any display.
    var lines: Float = 0
    var curvatureEnabled = true
    var fill = false
    /// Look settings (see TVController for presets).
    var interlaced = false
    /// Fraction of brightness a phosphor keeps after 1/60 s. 0 = off.
    var persistence: Float = 0.5
    var glow: Float = 0.14
    var grain: Float = 0.03

    var isPoweredOn: Bool {
        switch power { case .on, .turningOn: return true; default: return false }
    }

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        guard let url = Bundle.main.url(forResource: "CRT", withExtension: "metal"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("CRT.metal not found in bundle"); return nil
        }
        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "crt_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "crt_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "crt_vertex")
            pd.fragmentFunction = lib.makeFunction(name: "persist_fragment")
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            pd.colorAttachments[1].pixelFormat = .bgra8Unorm
            persistPipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            NSLog("Shader error: \(error)"); return nil
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        contentSampler = device.makeSamplerState(descriptor: sd)!
        sd.mipFilter = .notMipmapped
        osdSampler = device.makeSamplerState(descriptor: sd)!

        let w = OSDRenderer.width, h = OSDRenderer.height
        osdContext = OSDRenderer.makeContext()
        osdTexture = Self.makeTexture(device, w, h, mipmapped: false)
        blackTexture = Self.makeTexture(device, 2, 2, mipmapped: false)
        barsTexture = Self.makeTexture(device, w, h, mipmapped: true)
        super.init()

        let bars = OSDRenderer.colorBars()
        barsTexture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                            withBytes: bars.data!, bytesPerRow: bars.bytesPerRow)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: barsTexture)
            blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
        setOSD(OSDState())

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = self
    }

    private static func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int, mipmapped: Bool) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: mipmapped)
        d.usage = .shaderRead
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }

    // MARK: State changes

    func resetVideo() {
        videoTexture = nil
        videoAspect = 0
        sink?.discardPending()
    }

    func burstStatic(_ seconds: CFTimeInterval = 0.4) {
        staticUntil = CACurrentMediaTime() + seconds
    }

    /// Brief tracking glitch, e.g. after a skip.
    func tapeGlitch(_ seconds: CFTimeInterval = 0.35) {
        glitchUntil = CACurrentMediaTime() + seconds
    }

    func powerOff() { if isPoweredOn { power = .turningOff(CACurrentMediaTime()) } }
    func powerOn() { if !isPoweredOn { power = .turningOn(CACurrentMediaTime()) } }

    func setOSD(_ state: OSDState) {
        guard state != lastOSD else { return }
        lastOSD = state
        OSDRenderer.draw(state, in: osdContext)
        osdTexture.replace(region: MTLRegionMake2D(0, 0, OSDRenderer.width, OSDRenderer.height),
                           mipmapLevel: 0, withBytes: osdContext.data!, bytesPerRow: osdContext.bytesPerRow)
    }

    // MARK: Power animation

    private func ease(_ t: Double) -> Double { let x = min(max(t, 0), 1); return x * x * (3 - 2 * x) }

    private func powerParams(_ now: CFTimeInterval) -> (sx: Float, sy: Float, bright: Float, snow: Float) {
        switch power {
        case .on: return (1, 1, 1, 0)
        case .off: return (0, 0, 1, 0)
        case .turningOff(let t0):
            let t = now - t0
            if t < 0.18 { let k = ease(t / 0.18); return (1, Float(max(0.004, 1 - k)), Float(1 + 1.4 * k), 0) }
            if t < 0.42 { let k = ease((t - 0.18) / 0.24); return (Float(max(0.003, 1 - k)), 0.004, 2.4, 0) }
            if t < 0.75 { return (0.003, 0.005, 2.4, 0) }   // lingering dot
            power = .off
            return (0, 0, 1, 0)
        case .turningOn(let t0):
            let t = now - t0
            if t < 0.12 { let k = ease(t / 0.12); return (Float(max(0.003, k)), 0.004, 2.4, 0) }
            if t < 0.5 { let k = ease((t - 0.12) / 0.38); return (1, Float(max(0.004, k)), Float(2.4 - 1.4 * k), Float(0.6 * (1 - k))) }
            power = .on
            return (1, 1, 1, 0)
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func ensureTargets(_ size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return }
        if let t = curTexture, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        curTexture = device.makeTexture(descriptor: d)
        d.storageMode = .shared   // readable for snapshots
        accum = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        resetAccum = true
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        ensureTargets(size)
        guard let drawable = view.currentDrawable, let cur = curTexture, accum.count == 2,
              let cb = queue.makeCommandBuffer() else { return }
        frameIndex += 1

        // Pass 1: the CRT picture for this frame
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = cur
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        encodeFrame(cb, rpd, size: size)

        // Pass 2: phosphor persistence → screen + history
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 1.0 / 240), 0.1))
        lastFrameTime = now
        var decay: Float = resetAccum ? 0 : pow(persistence, dt * 60)
        resetAccum = false
        let next = 1 - accumIndex
        let pp = MTLRenderPassDescriptor()
        pp.colorAttachments[0].texture = drawable.texture
        pp.colorAttachments[0].loadAction = .dontCare
        pp.colorAttachments[0].storeAction = .store
        pp.colorAttachments[1].texture = accum[next]
        pp.colorAttachments[1].loadAction = .dontCare
        pp.colorAttachments[1].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pp) {
            enc.setRenderPipelineState(persistPipeline)
            enc.setFragmentBytes(&decay, length: MemoryLayout<Float>.size, index: 0)
            enc.setFragmentTexture(cur, index: 0)
            enc.setFragmentTexture(accum[accumIndex], index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        accumIndex = next
        cb.present(drawable)
        cb.commit()
        lastCommandBuffer = cb
    }

    /// The picture exactly as last shown on screen (including persistence and interlace).
    func snapshot(size: CGSize) -> CGImage? {
        guard accum.count == 2 else { return nil }
        lastCommandBuffer?.waitUntilCompleted()
        let tex = accum[accumIndex]
        let w = tex.width, h = tex.height
        let ctx = OSDRenderer.makeContext(width: w, height: h)
        tex.getBytes(ctx.data!, bytesPerRow: ctx.bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return ctx.makeImage()
    }

    private func encodeFrame(_ cb: MTLCommandBuffer, _ rpd: MTLRenderPassDescriptor, size: CGSize) {
        let now = CACurrentMediaTime()

        if source == .video, let sink {
            sink.withLatestFrame { ptr, w, h in
                if videoTexture == nil || videoTexture!.width != w || videoTexture!.height != h {
                    videoTexture = Self.makeTexture(device, w, h, mipmapped: true)
                }
                videoTexture!.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr, bytesPerRow: w * 4)
                videoNeedsMips = true
            }
        }
        if videoNeedsMips, let vt = videoTexture, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: vt)
            blit.endEncoding()
            videoNeedsMips = false
        }

        let content: MTLTexture
        switch source {
        case .bars: content = barsTexture
        case .video: content = videoTexture ?? blackTexture
        case .snow: content = blackTexture
        }

        let p = powerParams(now)
        var u = CRTUniforms()
        u.viewSize = SIMD2(Float(size.width), Float(size.height))
        var aspect = Double(content.width) / Double(content.height)
        if source == .video, videoAspect > 0 { aspect = videoAspect }
        u.contentSize = SIMD2(Float(Double(content.height) * aspect), Float(content.height))
        u.time = Float(now - startTime)
        // Auto: ~3 px per line, or ~2 px when interlaced (each field lights every other line)
        u.lines = lines > 0 ? lines : min(480, max(240, (Float(size.height) / (interlaced ? 2 : 3)).rounded()))
        u.hres = u.lines * 4 / 3
        u.curvature = curvatureEnabled ? 0.06 : 0.0
        u.squeezeX = p.sx
        u.squeezeY = p.sy
        u.brightness = p.bright
        let burst = Float(max(0, (staticUntil - now) / 0.4))
        u.staticAmount = max(source == .snow ? 1 : 0, burst, p.snow)
        u.fill = fill ? 1 : 0
        var target: Float = 0
        if source == .video {
            switch tapeMode {
            case .normal: target = 0
            case .paused: target = 0.22
            case .forward, .rewind: target = 1
            }
        }
        if now < glitchUntil { target = max(target, 0.7) }
        vhsLevel += (target - vhsLevel) * 0.25
        u.vhs = vhsLevel < 0.002 ? 0 : vhsLevel
        u.picBrightness = picBrightness
        u.picSaturation = picSaturation
        u.glow = glow
        u.grain = grain
        u.interlace = interlaced ? 1 : 0
        u.field = Float(frameIndex & 1)
        u.vhsDir = tapeMode == .rewind ? -1 : (tapeMode == .paused ? 0.04 : 1)
        let texelsPerVirtual = max(Float(content.height) / u.lines, Float(content.width) / u.hres)
        u.contentLod = max(0, log2(max(texelsPerVirtual, 1)) - 0.25)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<CRTUniforms>.stride, index: 0)
        enc.setFragmentTexture(content, index: 0)
        enc.setFragmentTexture(osdTexture, index: 1)
        enc.setFragmentSamplerState(contentSampler, index: 0)
        enc.setFragmentSamplerState(osdSampler, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
