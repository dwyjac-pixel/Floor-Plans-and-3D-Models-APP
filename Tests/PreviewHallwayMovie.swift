import AVFoundation
import CoreGraphics
import Metal
import SceneKit

@main
struct PreviewHallwayMovie {
    static func main() throws {
        let room = PreviewRoomScene(layout: PreviewLayout(room: PreviewReferenceRoom.bathroom()))
        guard let hall = PreviewHallway(room: room), let device = MTLCreateSystemDefaultDevice(),
              let entry = PreviewCamera.entry(in: room.layout) else {
            fatalError("The reference hallway or Metal renderer is unavailable.")
        }
        let near = PreviewLayout.wallThickness
        for index in 0...300 {
            let stop = hall.camera(at: Double(index) / 300)
            let relative = stop.plan - entry.wall.start
            let distance = relative.dot(entry.wall.inward)
            if (-near - 0.05...0.05).contains(distance) {
                let along = relative.dot(entry.wall.direction)
                precondition(along > entry.void.from + 0.10 && along < entry.void.to - 0.10)
                precondition(stop.eye.y < entry.void.head - 0.10)
            }
            if distance >= 0 {
                precondition(room.layout.contains(stop.plan))
                precondition(!room.layout.isInsideSolid(stop.plan, margin: 0.10))
            }
        }

        let width = 960, height = 720, fps = 30
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = room.scene
        renderer.pointOfView = room.cameraNode

        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 7_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        guard writer.startWriting() else { fatalError("Unable to start video: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for frame in 0..<210 {
            while !input.isReadyForMoreMediaData {
                precondition(writer.status == .writing)
                Thread.sleep(forTimeInterval: 0.005)
            }
            try autoreleasepool {
                room.place(at: hall.camera(at: Double(frame - 15) / 165))
                let snapshot = renderer.snapshot(atTime: Double(frame) / Double(fps),
                                                 with: bounds.size, antialiasingMode: .multisampling4X)
                guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let pool = adaptor.pixelBufferPool else { fatalError("Unable to render frame \(frame)") }
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                      let pixelBuffer else { fatalError("Unable to allocate frame \(frame)") }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
                context.draw(image, in: bounds)
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)))
                else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        print("Doorway clearance verified at 301 samples. Wrote 210 frames at 30 fps to \(output.path).")
    }
}
