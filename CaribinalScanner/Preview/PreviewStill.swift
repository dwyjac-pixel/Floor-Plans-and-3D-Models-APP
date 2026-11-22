import CoreText
import ImageIO
import Metal
import SceneKit

/// Client-ready pictures of the finished room, rendered off screen.
///
/// A still is drawn at twice its final size and scaled down, which gives
/// clean edges and crisp grout lines. Stills of two looks taken from the
/// same stop share the camera, exposure and lights exactly, so the only
/// difference between them is the finishes.
enum PreviewStill {
    /// Renders the room from a stop. The live camera is not moved.
    static func render(_ room: PreviewRoomScene, from stop: PreviewCamera.Stop, width: Int = 1600,
                       supersample: Int = 2) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(), let liveCamera = room.cameraNode.camera else { return nil }
        let height = Int((Double(width) / PreviewCamera.aspect).rounded())
        let eye = SCNNode()
        eye.camera = liveCamera.copy() as? SCNCamera
        PreviewRoomScene.aim(eye.camera, for: stop)
        eye.simdPosition = SIMD3(Float(stop.eye.x), Float(stop.eye.y), Float(stop.eye.z))
        eye.simdOrientation = PreviewRoomScene.orientation(headingDegrees: stop.headingDegrees, pitchDegrees: stop.pitchDegrees)
        room.scene.rootNode.addChildNode(eye)
        // From overhead the ceiling, bulkheads and light trims step aside.
        let ceilingWasHidden = room.overheadHidden.isHidden
        room.overheadHidden.isHidden = stop.kind == .overhead
        defer {
            eye.removeFromParentNode()
            room.overheadHidden.isHidden = ceilingWasHidden
        }

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = room.scene
        renderer.pointOfView = eye
        renderer.autoenablesDefaultLighting = false
        let size = CGSize(width: width * supersample, height: height * supersample)
        let shot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        #if os(macOS)
        guard let large = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let large = shot.cgImage else { return nil }
        #endif
        guard supersample > 1 else { return large }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return large }
        context.interpolationQuality = .high
        context.draw(large, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? large
    }

    /// Adds the caption band under a picture. The first line is the
    /// statement that this is an illustration from a named drawing.
    static func captioned(_ image: CGImage, lines: [String]) -> CGImage? {
        guard !lines.isEmpty else { return image }
        let width = image.width, scale = CGFloat(width) / 1600
        let headSize = 24 * scale, bodySize = 20 * scale, pad = 26 * scale, leading = 9 * scale
        let head = CTFontCreateUIFontForLanguage(.emphasizedSystem, headSize, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, headSize, nil)
        let body = CTFontCreateUIFontForLanguage(.system, bodySize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, bodySize, nil)
        let band = Int((pad * 2 + headSize + CGFloat(lines.count - 1) * (bodySize + leading)).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: image.height + band, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(PreviewTextures.color("F7F6F3"))
        context.fill(CGRect(x: 0, y: 0, width: width, height: band))
        context.draw(image, in: CGRect(x: 0, y: band, width: width, height: image.height))
        var baseline = CGFloat(band) - pad - headSize * 0.8
        for (index, text) in lines.enumerated() {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: index == 0 ? head : body,
                kCTForegroundColorAttributeName: PreviewTextures.color(index == 0 ? "1F2124" : "4A4D52"),
            ]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!)
            // Shrink a line that would run off the picture.
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let available = CGFloat(width) - 2 * pad
            context.saveGState()
            context.translateBy(x: pad, y: baseline)
            if bounds.width > available { context.scaleBy(x: available / bounds.width, y: available / bounds.width) }
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            baseline -= bodySize + leading
        }
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
