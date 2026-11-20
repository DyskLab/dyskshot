import AVFoundation
import CoreImage
import AppKit
import ScreenCaptureKit

// MARK: - Engine: ScreenCaptureKit stream → AVAssetWriter (MP4)

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Options {
        var fps: Int
        var showCursor: Bool
        var scale: CGFloat
        var codec: AVVideoCodecType
        var quality: Int
        var systemAudio: Bool
        var microphone: Bool
        var microphoneDeviceID: String?
        var maxHeight: Int = 0
        var mono: Bool = false
    }

    let outputURL: URL
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let queue = DispatchQueue(label: "com.dysklab.dyskshot.recorder")
    var onError: ((Error) -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    private static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) / 2 * 2) }

    func start(filter: SCContentFilter, sourceRect: CGRect, options o: Options) async throws {
        var scale = o.scale
        if o.maxHeight > 0, sourceRect.height * scale > CGFloat(o.maxHeight) { scale = CGFloat(o.maxHeight) / sourceRect.height }
        let w = Self.even(sourceRect.width * scale), h = Self.even(sourceRect.height * scale)
        let channels = o.mono ? 1 : 2

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        config.showsCursor = o.showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        config.capturesAudio = o.systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = o.microphone
        if o.microphone, let id = o.microphoneDeviceID, !id.isEmpty { config.microphoneCaptureDeviceID = id }
        config.sampleRate = 48000
        config.channelCount = channels

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bpp: Double = [0.06, 0.12, 0.25][min(max(o.quality, 0), 2)]
        let bitrate = Double(w * h * o.fps) * bpp
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: o.codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: o.fps,
                AVVideoMaxKeyFrameIntervalKey: o.fps * 2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoInput = video

        func audio() -> AVAssetWriterInput {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            return a
        }
        if o.systemAudio { audioInput = audio() }
        if o.microphone { micInput = audio() }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "DyskShot", code: 1) }
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if o.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if o.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                sessionStarted = true
            }
            if let v = videoInput, v.isReadyForMoreMediaData { v.append(sb) }
        case .audio:
            if sessionStarted, let a = audioInput, a.isReadyForMoreMediaData { a.append(sb) }
        case .microphone:
            if sessionStarted, let m = micInput, m.isReadyForMoreMediaData { m.append(sb) }
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    /// Stops capture and finalizes the file. Returns nil when nothing was recorded.
    func stop() async -> URL? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        guard let writer else { return nil }
        let started: Bool = queue.sync {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            micInput?.markAsFinished()
            return sessionStarted
        }
        guard started else { writer.cancelWriting(); return nil }
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }
}

// MARK: - GIF conversion

enum GIFEncoder {
    /// quality 0...10 (10 = full color); optimize merges identical consecutive frames.
    static func convert(video: URL, to gif: URL, fps: Int, maxWidth: Int, loop: Bool,
                        quality: Int = 10, optimize: Bool = true) async -> Bool {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration) else { return false }
        let seconds = CMTimeGetSeconds(duration)
        let count = max(1, Int(seconds * Double(fps)))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let tol = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        if maxWidth > 0, let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.width > CGFloat(maxWidth) {
            gen.maximumSize = CGSize(width: maxWidth, height: 0) // only downscale
        }

        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, count, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop ? 0 : 1]] as CFDictionary)
        let frameDelay = 1.0 / Double(fps)
        func props(_ d: Double) -> CFDictionary {
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d, kCGImagePropertyGIFUnclampedDelayTime: d]] as CFDictionary
        }
        let ci = CIContext(options: [.cacheIntermediates: false])
        let levels = quality >= 10 ? 0 : 6 + quality * 2 // fewer colour levels → smaller files

        var pending: (CGImage, Double, Data?)?
        var added = 0
        func flush() {
            guard let p = pending else { return }
            CGImageDestinationAddImage(dest, p.0, props(p.1))
            added += 1
        }
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / Double(fps), preferredTimescale: 600)
            guard var img = try? await gen.image(at: t).image else { continue }
            if levels > 0, let f = CIFilter(name: "CIColorPosterize") {
                f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
                f.setValue(levels, forKey: "inputLevels")
                if let out = f.outputImage, let cg = ci.createCGImage(out, from: out.extent) { img = cg }
            }
            let sig = optimize ? signature(img) : nil
            if optimize, let p = pending, let sig, p.2 == sig {
                pending = (p.0, p.1 + frameDelay, p.2)
                continue
            }
            flush()
            pending = (img, frameDelay, sig)
        }
        flush()
        guard added > 0 else { return false }
        return CGImageDestinationFinalize(dest)
    }

    /// Small downsampled fingerprint used to detect identical frames.
    private static func signature(_ img: CGImage) -> Data? {
        let w = 48, h = max(1, Int(Double(img.height) / Double(max(img.width, 1)) * 48))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data else { return nil }
        return Data(bytes: p, count: w * h * 4)
    }

    static func thumbnail(for url: URL) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 800, height: 800)
        return try? await gen.image(at: .zero).image
    }
}

// MARK: - Controller (selection, countdown, dim, controls, click/keystroke overlays)

@MainActor
final class RecordingController {
    static let shared = RecordingController()

    enum Kind { case video, gif }

    private(set) var isRecording = false
    private var preparing = false
    private var kind: Kind = .video
    private var recorder: ScreenRecorder?
    private var overlay: SelectionOverlayController?
    private var setup: RecordSetupController?
    private var startDate: Date?
    private var timer: Timer?
    private var dimWindows: [NSWindow] = []
    private var controls: RecordingControls?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var keystrokeHUD: KeystrokeHUD?
    private var rect: NSRect = .zero

    var elapsed: TimeInterval { startDate.map { Date().timeIntervalSince($0) } ?? 0 }
    var onStateChange: (() -> Void)?

    func toggle(_ kind: Kind) {
        if isRecording { stop() } else if let setup { setup.record(kind) } else { start(kind) }
    }

    /// Select an area, then show the setup HUD (Record GIF / Record Video).
    func start(_ kind: Kind) {
        guard !isRecording, !preparing, overlay == nil, setup == nil, CaptureController.ensurePermission() else { return }
        self.kind = kind
        if Prefs.bool("rec.rememberArea"), let r = Prefs.lastRecordArea, NSScreen.containing(r) != nil {
            showSetup(rect: r)
            return
        }
        var opts = SelectionOptions(allowsScreen: true)
        opts.hint = "Record: drag an area, click for fullscreen, Space for window · Esc: cancel"
        let ctrl = SelectionOverlayController(displays: NSScreen.screens.map { OverlayDisplay(screen: $0, image: nil) },
                                              windows: WindowList.onScreenWindows(), options: opts) { result in
            self.overlay = nil
            switch result {
            case .cancelled: return
            case .area(let r, _), .window(_, let r, _): self.showSetup(rect: r)
            case .screen(let d): self.showSetup(rect: d.screen.frame)
            }
        }
        overlay = ctrl
        ctrl.show()
    }

    private func showSetup(rect r: NSRect) {
        guard let screen = NSScreen.containing(r) else { return }
        let ctrl = RecordSetupController(rect: r, screen: screen, reselect: { [weak self] in
            guard let self else { return }
            self.setup = nil
            self.start(self.kind)
        }) { [weak self] kind, rect in
            guard let self else { return }
            self.setup = nil
            guard let kind else { return }
            self.kind = kind
            self.begin(rect: rect)
        }
        setup = ctrl
        ctrl.show()
    }

    private func begin(rect r: NSRect) {
        guard let screen = NSScreen.containing(r) else { return }
        rect = r.intersection(screen.frame).integral
        Prefs.lastRecordArea = rect
        preparing = true
        let go = { Task { @MainActor in await self.startRecording(on: screen) } }
        if Prefs.bool("rec.countdown") {
            Countdown.run(seconds: 3, on: screen) { _ = go() }
        } else {
            _ = go()
        }
    }

    private func startRecording(on screen: NSScreen) async {
        defer { preparing = false }
        if Prefs.bool("rec.dim") { showDim(screen: screen) }
        if Prefs.bool("rec.showControls") { controls = RecordingControls(around: rect, on: screen) }
        if Prefs.bool("rec.highlightClicks") { startClickHighlights() }
        if Prefs.bool("rec.showKeystrokes") { startKeystrokes(screen: screen) }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw NSError(domain: "DyskShot", code: 2) }
            var keepList = ClickHighlighter.windowIDs + (keystrokeHUD.map { [CGWindowID($0.windowNumber)] } ?? [])
            if let cam = CameraBubble.shared.windowID { keepList.append(cam) }
            let keep = Set(keepList)
            let filter = SCContentFilter(display: display, excludingWindows: ScreenCapturer.ownWindowsToExclude(content, keep: keep))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DyskShot", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("recording-\(UUID().uuidString).mp4")
            let rec = ScreenRecorder(outputURL: url)
            rec.onError = { error in
                DispatchQueue.main.async { MainActor.assumeIsolated { RecordingController.shared.failed(error) } }
            }
            let opts = ScreenRecorder.Options(
                fps: kind == .gif ? min(Prefs.recFPS, 30) : Prefs.recFPS,
                showCursor: Prefs.bool("rec.showCursor"),
                scale: Prefs.bool("rec.scale1x") ? 1 : screen.backingScaleFactor,
                codec: Prefs.int("rec.codec") == 1 ? .hevc : .h264,
                quality: Prefs.int("rec.quality"),
                systemAudio: kind == .video && Prefs.bool("rec.systemAudio"),
                microphone: kind == .video && Prefs.bool("rec.mic"),
                microphoneDeviceID: Prefs.string("rec.micDevice"),
                maxHeight: Prefs.recMaxHeight,
                mono: Prefs.bool("rec.mono"))
            try await rec.start(filter: filter, sourceRect: screen.displayLocalTopLeft(rect), options: opts)
            recorder = rec
            isRecording = true
            startDate = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let rc = RecordingController.shared
                    rc.controls?.update(elapsed: rc.elapsed)
                    rc.onStateChange?()
                }
            }
            onStateChange?()
        } catch {
            failed(error)
        }
    }

    func stop() {
        guard isRecording, let rec = recorder else { return }
        let kind = self.kind
        teardown()
        Task { @MainActor in
            guard let url = await rec.stop() else {
                Toast.show("Recording failed", symbol: "xmark.octagon.fill")
                return
            }
            if kind == .gif {
                Toast.show("Creating GIF…", symbol: "hourglass")
                let gif = url.deletingPathExtension().appendingPathExtension("gif")
                let ok = await GIFEncoder.convert(video: url, to: gif, fps: Prefs.gifFPS,
                                                  maxWidth: Prefs.gifMaxWidth, loop: Prefs.bool("gif.loop"),
                                                  quality: Prefs.int("gif.quality"), optimize: Prefs.bool("gif.optimize"))
                try? FileManager.default.removeItem(at: url)
                guard ok else { Toast.show("GIF export failed", symbol: "xmark.octagon.fill"); return }
                await deliver(gif, type: "GIF")
            } else {
                await deliver(url, type: "Recording")
            }
        }
    }

    func cancel() {
        guard isRecording, let rec = recorder else { return }
        teardown()
        Task { await rec.cancel() }
        Toast.show("Recording discarded", symbol: "trash")
    }

    private func failed(_ error: Error) {
        let rec = recorder
        teardown()
        Task { await rec?.cancel() }
        Toast.show("Recording failed: \(error.localizedDescription)", symbol: "xmark.octagon.fill")
    }

    private func teardown() {
        isRecording = false
        recorder = nil
        startDate = nil
        timer?.invalidate()
        timer = nil
        dimWindows.forEach { $0.orderOut(nil) }
        dimWindows.removeAll()
        controls?.close()
        controls = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        keystrokeHUD?.orderOut(nil)
        keystrokeHUD = nil
        CameraBubble.shared.hide()
        onStateChange?()
    }

    /// Runs the "After capture → Recording" actions.
    private func deliver(_ recorded: URL, type: String) async {
        CaptureController.playShutter()
        var tempURL = recorded
        if type != "GIF", Prefs.bool("rec.autoCompress") {
            let out = recorded.deletingLastPathComponent().appendingPathComponent("compressed-\(UUID().uuidString).mp4")
            if (try? await VideoExporter.compress(recorded, to: out)) != nil,
               let a = try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               let b = try? recorded.resourceValues(forKeys: [.fileSizeKey]).fileSize, a < b {
                tempURL = out
            }
        }
        var url = tempURL
        var saved = false
        if Prefs.bool("after.rec.save"), let dest = Output.saveFile(tempURL, type: type) {
            url = dest
            saved = true
        }
        if Prefs.bool("after.rec.copy") { Output.copyFile(url) }
        if Prefs.bool("after.rec.open") { NSWorkspace.shared.open(url) }
        if Prefs.bool("after.rec.edit"), type != "GIF" { VideoEditorWindowController.edit(url) }
        if Prefs.bool("after.rec.upload") { Cloud.upload(file: url) }
        if Prefs.bool("after.rec.quick") {
            let thumb = await GIFEncoder.thumbnail(for: url)
            QuickAccessManager.shared.show(.file(url, thumbnail: thumb, type: type, saved: saved))
        } else if saved {
            Toast.show("Saved \(url.lastPathComponent)")
        }
    }

    // MARK: Dim

    private func showDim(screen: NSScreen) {
        for s in NSScreen.screens {
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let hole = s == screen ? rect.offsetBy(dx: -s.frame.minX, dy: -s.frame.minY) : nil
            w.contentView = DimView(frame: NSRect(origin: .zero, size: s.frame.size), hole: hole)
            w.orderFrontRegardless()
            dimWindows.append(w)
        }
    }

    // MARK: Clicks & keystrokes

    private func startClickHighlights() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { ClickHighlighter.show(at: NSEvent.mouseLocation) }
        }
    }

    private func startKeystrokes(screen: NSScreen) {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        guard trusted else {
            Toast.show("Allow Accessibility to show keystrokes", symbol: "keyboard")
            return
        }
        let hud = KeystrokeHUD(bottomOf: rect)
        keystrokeHUD = hud
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let text = Shortcut(event: event).display
            MainActor.assumeIsolated { RecordingController.shared.keystrokeHUD?.show(text) }
        }
    }
}

final class DimView: NSView {
    let hole: NSRect?
    init(frame: NSRect, hole: NSRect?) {
        self.hole = hole
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let hole {
            path.appendRect(hole.insetBy(dx: -2, dy: -2))
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        path.fill()
        if let hole {
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let b = NSBezierPath(rect: hole.insetBy(dx: -1.5, dy: -1.5))
            b.lineWidth = 1
            b.setLineDash([6, 4], count: 2, phase: 0)
            b.stroke()
        }
    }
}

// MARK: - Floating controls (timer, stop, discard)

@MainActor
final class RecordingControls {
    private let panel: NSPanel
    private let timeLabel = NSTextField(labelWithString: "0:00")

    init(around rect: NSRect, on screen: NSScreen) {
        let size = NSSize(width: 146, height: 34)
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < screen.frame.minY + 10 { origin.y = rect.minY + 10 }
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = size.height / 2
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        // Pulsing red dot
        let dot = NSView(frame: NSRect(x: 13, y: (size.height - 8) / 2, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.alignment = .left
        timeLabel.frame = NSRect(x: 27, y: (size.height - 17) / 2, width: 46, height: 17)

        let sep = NSView(frame: NSRect(x: 76, y: 9, width: 1, height: size.height - 18))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor

        func circle(_ symbol: String, _ tip: String, x: CGFloat, fill: NSColor, tint: NSColor) -> FirstMouseButton {
            let b = FirstMouseButton(frame: NSRect(x: x, y: (size.height - 24) / 2, width: 24, height: 24))
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            b.imagePosition = .imageOnly
            b.isBordered = false
            b.toolTip = tip
            b.contentTintColor = tint
            b.wantsLayer = true
            b.layer?.cornerRadius = 12
            b.layer?.backgroundColor = fill.cgColor
            return b
        }
        let discard = circle("trash.fill", "Discard recording", x: 84, fill: NSColor(white: 1, alpha: 0.14), tint: .white)
        let stop = circle("stop.fill", "Stop recording", x: size.width - 24 - 6, fill: .systemRed, tint: .white)

        [dot, timeLabel, sep, discard, stop].forEach(effect.addSubview)
        panel.contentView = effect

        stop.target = Handler.shared
        stop.action = #selector(Handler.stop)
        discard.target = Handler.shared
        discard.action = #selector(Handler.discard)
        panel.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval) {
        let s = Int(elapsed)
        timeLabel.stringValue = String(format: "%d:%02d", s / 60, s % 60)
    }

    func close() { panel.orderOut(nil) }
    var debugView: NSView? { panel.contentView }

    final class Handler: NSObject {
        static let shared = Handler()
        @objc func stop() { MainActor.assumeIsolated { RecordingController.shared.stop() } }
        @objc func discard() { MainActor.assumeIsolated { RecordingController.shared.cancel() } }
    }
}

// MARK: - Click highlight rings (included in the recording)

@MainActor
enum ClickHighlighter {
    private static var live: [NSWindow] = []
    static var windowIDs: [CGWindowID] { live.map { CGWindowID($0.windowNumber) } }

    static func show(at p: NSPoint) {
        let d: CGFloat = 44
        let w = NSWindow(contentRect: NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        v.wantsLayer = true
        v.layer?.cornerRadius = d / 2
        v.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        v.layer?.borderColor = NSColor.systemYellow.cgColor
        v.layer?.borderWidth = 2
        w.contentView = v
        w.orderFrontRegardless()
        live.append(w)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            w.animator().alphaValue = 0
        }) {
            MainActor.assumeIsolated {
                w.orderOut(nil)
                live.removeAll { $0 === w }
            }
        }
    }
}

// MARK: - Keystroke HUD (included in the recording)

final class KeystrokeHUD: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init(bottomOf rect: NSRect) {
        super.init(contentRect: NSRect(x: rect.midX - 100, y: rect.minY + 30, width: 200, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.alignment = .center
        label.frame = effect.bounds.insetBy(dx: 8, dy: 9)
        label.autoresizingMask = [.width]
        effect.addSubview(label)
        contentView = effect
        alphaValue = 0
        orderFrontRegardless()
    }

    @MainActor
    func show(_ text: String) {
        label.stringValue = text
        let w = max(80, label.attributedStringValue.size().width + 40)
        let f = frame
        setFrame(NSRect(x: f.midX - w / 2, y: f.minY, width: w, height: f.height), display: true)
        alphaValue = 1
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { _ in self?.animator().alphaValue = 0 }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
