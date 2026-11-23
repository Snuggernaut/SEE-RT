import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Realistic lighting for a cabinet, built once per skin from its silhouette and cached:
/// highlights on edges facing the light (top left), shading on the others, a soft sheen,
/// fine moulded-plastic texture, shadows on the wall behind and under the base, and the ring
/// where the picture's light spills onto the bezel. Independent of the colour finish.
@MainActor
final class CabinetLighting {
    struct Layers {
        let light: CGImage      // white highlights + black shading, drawn normally over the cabinet
        let texture: CGImage    // grey noise around 50 %, drawn with soft light
        let glowRing: CGImage   // grayscale mask just outside the glass, filled with the picture's colour
        let shadow: CGImage     // covers the padded canvas; drawn before the cabinet
    }

    /// Design units of transparent margin around the cabinet, room for the drawn shadow.
    static let pad = NSEdgeInsets(top: 26, left: 40, bottom: 60, right: 40)
    private static let k: CGFloat = 2          // pixels per design unit in the cached layers
    private static var cache: [String: Layers] = [:]
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    static func layers(for skin: TVSkin) -> Layers? {
        if let l = cache[skin.id] { return l }
        guard let l = build(skin) else { return nil }
        cache[skin.id] = l
        return l
    }

    // MARK: Building

    private static func build(_ skin: TVSkin) -> Layers? {
        let k = Self.k
        let W = skin.design.width * k, H = skin.design.height * k
        let ext = CGRect(x: 0, y: 0, width: W, height: H)

        // Silhouette: draw the cabinet once and keep its alpha
        guard let sil = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        sil.translateBy(x: 0, y: H); sil.scaleBy(x: k, y: -k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: sil, flipped: true)
        skin.draw(skin.finishes[0], SkinState())
        NSGraphicsContext.restoreGraphicsState()
        guard let silImage = sil.makeImage() else { return nil }
        let base = baseSpan(sil, W: Int(W), H: Int(H))

        let src = CIImage(cgImage: silImage)
        let alpha = src.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: ext)

        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * k, y: H - r.maxY * k, width: r.width * k, height: r.height * k) }
        func mask(_ draw: (CGContext) -> Void) -> CIImage {
            let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            c.setFillColor(gray: 0, alpha: 1); c.fill(ext)
            c.setFillColor(gray: 1, alpha: 1); draw(c)
            return CIImage(cgImage: c.makeImage()!)
        }
        func blur(_ i: CIImage, _ sigma: CGFloat) -> CIImage { i.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ext) }
        func mul(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
        func sub(_ a: CIImage, _ b: CIImage) -> CIImage { b.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: a]) }
        func gain(_ i: CIImage, _ g: CGFloat) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0)])
                .applyingFilter("CIColorClamp")
        }
        func tinted(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ m: CIImage) -> CIImage {
            let f = CIFilter.blendWithMask()
            f.inputImage = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: ext)
            f.backgroundImage = CIImage.empty().cropped(to: ext)
            f.maskImage = m
            return f.outputImage!.cropped(to: ext)
        }

        let s = px(skin.screenRect)
        let corner = skin.screenCorner * k
        let screenM = mask { $0.addPath(CGPath(roundedRect: s, cornerWidth: corner, cornerHeight: corner, transform: nil)); $0.fillPath() }
        let bodyM = mul(alpha, screenM.applyingFilter("CIColorInvert"))

        // Edges facing the light (top left) catch it; the others fall into shade
        let shape = blur(bodyM, 5 * k)
        let d = 4 * k
        let lit = gain(mul(sub(shape, shape.transformed(by: .init(translationX: d, y: -d))), alpha), 0.55)
        let shaded = gain(mul(sub(shape, shape.transformed(by: .init(translationX: -d, y: d))), alpha), 0.6)
        // Broad sheen from the top left, and the cabinet falling off into shade toward its edges
        let sheen = CIFilter.radialGradient()
        sheen.center = CGPoint(x: W * 0.18, y: H * 0.92); sheen.radius0 = 0; sheen.radius1 = Float(W * 0.75)
        sheen.color0 = CIColor(red: 0.10, green: 0.10, blue: 0.10); sheen.color1 = CIColor(red: 0, green: 0, blue: 0)
        let falloff = CIFilter.radialGradient()
        falloff.center = CGPoint(x: W * 0.5, y: H * 0.55); falloff.radius0 = Float(W * 0.35); falloff.radius1 = Float(W * 0.75)
        falloff.color0 = CIColor(red: 0, green: 0, blue: 0); falloff.color1 = CIColor(red: 0.22, green: 0.22, blue: 0.22)
        let whiteM = mul(lit.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey:
                            mul(sheen.outputImage!.cropped(to: ext), bodyM)]).applyingFilter("CIColorClamp"), bodyM)
        let blackM = mul(shaded.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey:
                            mul(falloff.outputImage!.cropped(to: ext), bodyM)]).applyingFilter("CIColorClamp"), bodyM)
        let light = tinted(1, 1, 1, whiteM).composited(over: tinted(0, 0, 0, blackM))

        // Fine moulded texture: soft grey noise, masked to the cabinet
        let noise = CIFilter.randomGenerator().outputImage!
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
            .applyingGaussianBlur(sigma: 0.8).cropped(to: ext)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.10, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.10, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0.10, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0.45, y: 0.45, z: 0.45, w: 1)])
        let texF = CIFilter.blendWithMask()
        texF.inputImage = noise; texF.backgroundImage = CIImage.empty().cropped(to: ext); texF.maskImage = bodyM
        let texture = texF.outputImage!.cropped(to: ext)

        // Where the picture's light lands: a narrow band just outside the glass
        let ring = mul(sub(blur(screenM, 12 * k), screenM).applyingFilter("CIColorClamp"), bodyM)

        // Shadows on the padded canvas: a soft one on the wall behind, a tight one under the base
        let pad = Self.pad
        let PW = (skin.design.width + pad.left + pad.right) * k, PH = (skin.design.height + pad.top + pad.bottom) * k
        let pext = CGRect(x: 0, y: 0, width: PW, height: PH)
        let placed = alpha.transformed(by: .init(translationX: pad.left * k, y: pad.bottom * k))
        func soft(_ i: CIImage, _ sigma: CGFloat, dy: CGFloat, _ op: CGFloat) -> CIImage {
            gain(i.transformed(by: .init(translationX: 0, y: -dy)).composited(over: CIImage(color: .black).cropped(to: pext))
                .clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: pext), op)
        }
        var shadowM = soft(placed, 14 * k, dy: 12 * k, 0.36)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: soft(placed, 3 * k, dy: 2 * k, 0.30)])
        if let base {
            let footY = pad.bottom * k + (H - base.y)      // CI y of the bottom of the cabinet
            let c = CGContext(data: nil, width: Int(PW), height: Int(PH), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            c.setFillColor(gray: 0, alpha: 1); c.fill(pext)
            c.setFillColor(gray: 1, alpha: 1)
            let w = base.x1 - base.x0
            c.fillEllipse(in: CGRect(x: pad.left * k + base.x0 + w * 0.02, y: footY - 7 * k, width: w * 0.96, height: 12 * k))
            let contact = gain(CIImage(cgImage: c.makeImage()!).clampedToExtent().applyingGaussianBlur(sigma: 5 * k).cropped(to: pext), 0.8)
            shadowM = shadowM.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: contact])
        }
        let sf = CIFilter.blendWithMask()
        sf.inputImage = CIImage(color: .black).cropped(to: pext); sf.backgroundImage = CIImage.empty().cropped(to: pext)
        sf.maskImage = shadowM

        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let lightCG = ci.createCGImage(light, from: ext, format: .RGBA8, colorSpace: rgb),
              let texCG = ci.createCGImage(texture, from: ext, format: .RGBA8, colorSpace: rgb),
              let ringCG = ci.createCGImage(ring, from: ext, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
              let shadowCG = ci.createCGImage(sf.outputImage!.cropped(to: pext), from: pext, format: .RGBA8, colorSpace: rgb)
        else { return nil }
        return Layers(light: lightCG, texture: texCG, glowRing: ringCG, shadow: shadowCG)
    }

    /// The bottom edge of the cabinet (in pixels, top-left origin): the lowest opaque row and its extent.
    private static func baseSpan(_ c: CGContext, W: Int, H: Int) -> (y: CGFloat, x0: CGFloat, x1: CGFloat)? {
        guard let data = c.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self), bpr = c.bytesPerRow
        for y in stride(from: H - 1, through: 0, by: -1) {
            var x0 = -1, x1 = -1
            for x in 0..<W where p[y * bpr + x * 4 + 3] > 200 {
                if x0 < 0 { x0 = x }
                x1 = x
            }
            if x1 - x0 > W / 10 { return (CGFloat(y + 1), CGFloat(x0), CGFloat(x1 + 1)) }
        }
        return nil
    }
}
