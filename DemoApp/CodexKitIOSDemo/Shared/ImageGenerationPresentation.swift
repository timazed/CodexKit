import CodexKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageGenerationOutputControls: View {
    @Bindable var images: ImageGenerationDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Output", selection: $images.outputFormat) {
                Text("PNG image").tag(AgentImageOutputFormat.png)
                Text("Animated GIF").tag(AgentImageOutputFormat.gif)
            }.pickerStyle(.segmented)
            if images.outputFormat == .gif {
                Text("GIF generation requires provider access. You can try playback locally with the sample.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Preview sample animation") { images.showAnimationSample() }
                    .disabled(images.isBusy)
                Toggle("Custom animation settings", isOn: $images.customAnimation)
                if images.customAnimation {
                    Stepper("Frames: \(images.frameCount)", value: $images.frameCount, in: 2...16)
                    Stepper("Frame duration: \(images.frameDurationMilliseconds) ms",
                        value: $images.frameDurationMilliseconds, in: 20...2_000, step: 20)
                } else {
                    Text("Frame count and timing use service defaults.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Quality and dimensions are chosen by the service.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GeneratedImagePreview: View {
    let image: AgentImageAttachment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation: DemoImageAnimation?
    @State private var stillFrame: CGImage?
    @State private var isPlaying = true
    @State private var startedAt = Date()
    @State private var pausedElapsed: TimeInterval = 0

    var body: some View {
        VStack(spacing: 8) {
            if image.mimeType == .gif {
                if let animation {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { timeline in
                        let elapsed = pausedElapsed + (isPlaying ? timeline.date.timeIntervalSince(startedAt) : 0)
                        Image(decorative: animation.frames[animation.frameIndex(elapsed: elapsed)], scale: 1)
                            .resizable().scaledToFit().frame(maxHeight: 480)
                    }.accessibilityLabel("Generated animated GIF")
                    HStack {
                        Button(isPlaying ? "Pause animation" : "Play animation") {
                            if isPlaying { pause() }
                            else { startedAt = Date(); isPlaying = true }
                        }
                        Text("\(animation.frames.count) frames · \(animation.duration.formatted(.number.precision(.fractionLength(2)))) s loop")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Animation preview unavailable. You can still save the original GIF.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let stillFrame {
                Image(decorative: stillFrame, scale: 1).resizable().scaledToFit().frame(maxHeight: 480)
            }
        }
        .task(id: image.id) {
            animation = image.mimeType == .gif ? DemoImageAnimation(data: image.data) : nil
            if image.mimeType != .gif, let source = CGImageSourceCreateWithData(image.data as CFData, nil) {
                stillFrame = CGImageSourceCreateImageAtIndex(source, 0, nil)
            } else { stillFrame = nil }
            startedAt = Date()
            pausedElapsed = 0
            isPlaying = !reduceMotion
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { pause() } }
        .onDisappear { pause() }
    }
    private func pause() {
        guard isPlaying else { return }
        pausedElapsed += Date().timeIntervalSince(startedAt)
        isPlaying = false
    }
}

/// Shared by playback and the signed demo verifier; decoding is done once per result.
struct DemoImageAnimation {
    let frames: [CGImage]
    let delays: [TimeInterval]
    var duration: TimeInterval { delays.reduce(0, +) }

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) >= 2, CGImageSourceGetCount(source) <= 16 else { return nil }
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            frames.append(frame)
            delays.append(delay.isFinite ? min(60, max(0.02, delay)) : 0.1)
        }
        self.frames = frames
        self.delays = delays
    }

    static func sampleGIF() throws -> Data {
        let data = NSMutableData()
        let positions = [16, 24, 32, 40, 48, 56, 48, 32]
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
            positions.count, nil),
              let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for x in positions {
            context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.05, alpha: 1))
            context.fillEllipse(in: CGRect(x: x, y: 28, width: 20, height: 20))
            guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    func frameIndex(elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, elapsed > 0, duration > 0 else { return 0 }
        var position = elapsed.truncatingRemainder(dividingBy: duration)
        for (index, delay) in delays.enumerated() {
            if position < delay { return index }
            position -= delay
        }
        return 0
    }
}

extension AgentGeneratedImage {
    var demoExportType: UTType { image.mimeType == .gif ? .gif : .png }
}
