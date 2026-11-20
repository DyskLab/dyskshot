import AVFoundation
import AVKit
import AppKit

// MARK: - Export engine (trim + scale + bitrate + audio) via AVAssetReader → AVAssetWriter

enum VideoExporter {
    enum AudioMode: Int { case keep, mono, mute, volume }

    struct Options {
        var range: CMTimeRange
        var renderSize: CGSize
        var quality: Int // 0...6 (bitrate mode)
        var audio: AudioMode
        var volume: Float
        var codec: AVVideoCodecType = .h264
        /// When set, encode with constant quality (0...1) instead of a target bitrate.
        var constantQuality: Float?
    }

    static let bitsPerPixel: [Double] = [0.02, 0.035, 0.06, 0.09, 0.13, 0.19, 0.28]
    static let qualityNames = ["Lowest", "Very Low", "Low", "Medium", "High", "Very High", "Highest"]
    /// Constant-quality level used by "Compress" — visually lossless for screen content.
    static let losslessLookingQuality: Float = 0.70

    static func bitrate(size: CGSize, fps: Float, quality: Int) -> Double {
        Double(size.width * size.height) * Double(max(fps, 1)) * bitsPerPixel[min(max(quality, 0), 6)]
    }

    static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) / 2 * 2) }

    static func export(asset: AVAsset, to url: URL, options o: Options, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "DyskShot", code: 10, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let oriented = natural.applying(transform)
        let srcSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let w = even(o.renderSize.width), h = even(o.renderSize.height)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = o.range

        // Same size & orientation → read frames directly (keeps variable frame timing of screen recordings).
        let pixelSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let videoOut: AVAssetReaderOutput
        if transform.isIdentity, w == even(srcSize.width), h == even(srcSize.height) {
            // Native YUV avoids a lossy YUV→RGB→YUV round trip.
            videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
        } else {
            let comp = AVMutableVideoComposition()
            comp.renderSize = CGSize(width: w, height: h)
            comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let scale = CGAffineTransform(scaleX: CGFloat(w) / srcSize.width, y: CGFloat(h) / srcSize.height)
            layer.setTransform(transform.concatenating(scale), at: .zero)
            instruction.layerInstructions = [layer]
            comp.instructions = [instruction]
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: pixelSettings)
            out.videoComposition = comp
            videoOut = out
        }
        reader.add(videoOut)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var compression: [String: Any] = [AVVideoMaxKeyFrameIntervalKey: Int(max(fps, 1) * 2)]
        if let q = o.constantQuality {
            compression[AVVideoQualityKey] = q
        } else {
            compression[AVVideoAverageBitRateKey] = bitrate(size: CGSize(width: w, height: h), fps: fps, quality: o.quality)
        }
        if o.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: o.codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
        ]
        // Keep the source's colour tags (untagged sources are treated as BT.709) so pixel values aren't converted.
        let ext = (try? await videoTrack.load(.formatDescriptions).first).flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: ext[kCVImageBufferColorPrimariesKey as String] as? String ?? AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: ext[kCVImageBufferTransferFunctionKey as String] as? String ?? AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: ext[kCVImageBufferYCbCrMatrixKey as String] as? String ?? AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        if o.codec == .hevc { videoIn.mediaTimeScale = 600 }
        writer.add(videoIn)

        // Audio: passthrough (untouched) when kept, otherwise decode → mix → AAC.
        var audioPairs: [(AVAssetWriterInput, AVAssetReaderOutput)] = []
        if o.audio == .keep {
            for track in audioTracks {
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(out) else { continue }
                reader.add(out)
                let hint = try await track.load(.formatDescriptions).first
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                guard writer.canAdd(input) else { continue }
                writer.add(input)
                audioPairs.append((input, out))
            }
        } else if o.audio != .mute, !audioTracks.isEmpty {
            let channels = o.audio == .mono ? 1 : 2
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels,
            ])
            if o.audio == .volume {
                let mix = AVMutableAudioMix()
                mix.inputParameters = audioTracks.map {
                    let p = AVMutableAudioMixInputParameters(track: $0)
                    p.setVolume(o.volume, at: .zero)
                    return p
                }
                out.audioMix = mix
            }
            reader.add(out)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ])
            writer.add(input)
            audioPairs.append((input, out))
        }

        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "DyskShot", code: 11) }
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "DyskShot", code: 12) }
        writer.startSession(atSourceTime: o.range.start)

        let total = max(CMTimeGetSeconds(o.range.duration), 0.001)
        let start = CMTimeGetSeconds(o.range.start)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, reportsProgress: Bool) {
                group.enter()
                var finished = false
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "dyskshot.export.\(label)")) {
                    while input.isReadyForMoreMediaData && !finished {
                        if let sb = output.copyNextSampleBuffer() {
                            input.append(sb)
                            if reportsProgress {
                                progress(min(1, (CMTimeGetSeconds(sb.presentationTimeStamp) - start) / total))
                            }
                        } else {
                            finished = true
                            input.markAsFinished()
                            group.leave()
                        }
                    }
                }
            }
            pump(videoIn, videoOut, label: "video", reportsProgress: true)
            for (i, pair) in audioPairs.enumerated() { pump(pair.0, pair.1, label: "audio\(i)", reportsProgress: false) }
            group.notify(queue: .global()) { cont.resume() }
        }

        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? NSError(domain: "DyskShot", code: 13) }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "DyskShot", code: 14) }
        progress(1)
    }

    /// Re-encodes with HEVC at a visually lossless constant quality, same resolution/fps, audio untouched.
    static func compress(_ src: URL, to dst: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "DyskShot", code: 10, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let opts = Options(range: CMTimeRange(start: .zero, duration: duration),
                           renderSize: CGSize(width: abs(size.width), height: abs(size.height)),
                           quality: 6, audio: .keep, volume: 1, codec: .hevc, constantQuality: losslessLookingQuality)
        try await export(asset: asset, to: dst, options: opts, progress: progress)
    }
}

// MARK: - Compress UI entry

@MainActor
enum VideoCompressor {
    /// Compresses next to the original ("… (compressed).mp4"); keeps the original if it wouldn't get smaller.
    static func run(_ url: URL, showResult: Bool = true) {
        Toast.show("Compressing \(url.lastPathComponent)…", symbol: "arrow.down.right.and.arrow.up.left")
        let base = url.deletingPathExtension().lastPathComponent
        var out = url.deletingLastPathComponent().appendingPathComponent("\(base) (compressed).mp4")
        if !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) {
            out = FileManager.default.temporaryDirectory.appendingPathComponent("\(base) (compressed).mp4")
        }
        let target = out
        Task { @MainActor in
            do {
                try await VideoExporter.compress(url, to: target)
                let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let after = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard after > 0, after < before else {
                    try? FileManager.default.removeItem(at: target)
                    Toast.show("Already optimized — original kept", symbol: "checkmark.seal")
                    return
                }
                let f = ByteCountFormatter()
                f.countStyle = .file
                let pct = Int((1 - Double(after) / Double(max(before, 1))) * 100)
                Toast.show("\(f.string(fromByteCount: Int64(before))) → \(f.string(fromByteCount: Int64(after))) (−\(pct)%)",
                           symbol: "arrow.down.right.and.arrow.up.left")
                if showResult {
                    let thumb = await GIFEncoder.thumbnail(for: target)
                    QuickAccessManager.shared.show(.file(target, thumbnail: thumb, type: "Recording", saved: true))
                }
            } catch {
                Toast.show("Compress failed: \(error.localizedDescription)", symbol: "xmark.octagon.fill")
            }
        }
    }
}

// MARK: - Window

@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [VideoEditorWindowController] = []

    private let url: URL
    private let asset: AVURLAsset
    private let onDone: (URL) -> Void
    private let playerView = AVPlayerView()
    private var sourceSize = CGSize(width: 1920, height: 1080)
    private var fps: Float = 30
    private var duration: Double = 0
    private var hasAudio = false

    private let qualitySlider = NSSlider(value: 3, minValue: 0, maxValue: 6, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Medium")
    private let dimensionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codecPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keepQualityCheck = NSButton(checkboxWithTitle: "Keep original quality (smallest file)", target: nil, action: nil)
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var audioRadios: [NSButton] = []
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let estimateLabel = NSTextField(labelWithString: "Estimated file size: —")
    private let trimButton = NSButton(title: "Trim…", target: nil, action: nil)
    private let convertButton = NSButton(title: "Convert", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var dimensionPresets: [(String, CGSize?)] = []
    private var exporting = false

    /// Opens the editor; the converted file is saved to the recordings folder and shown in Quick Access.
    static func edit(_ url: URL) {
        open(url: url) { out in
            Task { @MainActor in
                let dest = Output.saveFile(out, type: "Recording") ?? out
                let thumb = await GIFEncoder.thumbnail(for: dest)
                QuickAccessManager.shared.show(.file(dest, thumbnail: thumb, type: "Recording", saved: dest != out))
            }
        }
    }

    static func open(url: URL, onDone: @escaping (URL) -> Void) {
        let c = VideoEditorWindowController(url: url, onDone: onDone)
        open.append(c)
        NSApp.activate()
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        Task { await c.load() }
    }

    init(url: URL, onDone: @escaping (URL) -> Void) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.onDone = onDone
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "Edit Video — \(url.lastPathComponent)"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 640)
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.open.removeAll { $0 === self }
    }

    // MARK: Load

    private func load() async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let natural = try await track.load(.naturalSize)
            let t = try await track.load(.preferredTransform)
            let o = natural.applying(t)
            sourceSize = CGSize(width: abs(o.width), height: abs(o.height))
            fps = try await track.load(.nominalFrameRate)
            duration = CMTimeGetSeconds(try await asset.load(.duration))
            hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        } catch {
            Toast.show("Can't open video", symbol: "xmark.octagon.fill")
            return
        }
        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        setupDimensions()
        audioRadios.forEach { $0.isEnabled = hasAudio }
        audioChanged()
        keepQualityChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self.beginTrim() } }
    }

    // MARK: UI

    private func card() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        playerView.controlsStyle = .inline
        playerView.showsFrameSteppingButtons = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        // Left card: quality + dimensions
        qualitySlider.numberOfTickMarks = 7
        qualitySlider.allowsTickMarkValuesOnly = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        qualityLabel.textColor = .secondaryLabelColor
        dimensionPopup.target = self
        dimensionPopup.action = #selector(dimensionChanged)
        dimensionPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        for f in [widthField, heightField] {
            f.widthAnchor.constraint(equalToConstant: 90).isActive = true
            f.target = self
            f.action = #selector(sizeTyped(_:))
            f.formatter = { let n = NumberFormatter(); n.allowsFloats = false; n.minimum = 16; n.maximum = 8192; return n }()
        }
        codecPopup.addItems(withTitles: ["H.264 (compatible)", "HEVC / H.265 (smaller)"])
        codecPopup.selectItem(at: 1)
        codecPopup.target = self
        codecPopup.action = #selector(qualityChanged)
        keepQualityCheck.target = self
        keepQualityCheck.action = #selector(keepQualityChanged)
        keepQualityCheck.state = .on
        keepQualityCheck.toolTip = "HEVC at visually lossless constant quality — usually 40–80% smaller for screen recordings"
        let left = NSGridView(views: [
            [NSTextField(labelWithString: "Compression:"), keepQualityCheck],
            [NSTextField(labelWithString: "Format:"), codecPopup],
            [NSTextField(labelWithString: "Video quality:"), NSStackView(views: [qualitySlider, qualityLabel])],
            [NSTextField(labelWithString: "Dimensions:"), dimensionPopup],
            [NSTextField(labelWithString: "Width:"), widthField],
            [NSTextField(labelWithString: "Height:"), heightField],
        ])
        left.column(at: 0).xPlacement = .trailing
        left.rowAlignment = .firstBaseline
        left.rowSpacing = 14

        // Right card: audio
        let titles = ["Don't change", "Convert to mono", "Mute", "Change volume"]
        audioRadios = titles.enumerated().map { i, t in
            let b = NSButton(radioButtonWithTitle: t, target: self, action: #selector(audioChanged))
            b.tag = i
            b.state = i == 0 ? .on : .off
            return b
        }
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.numberOfTickMarks = 3
        volumeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let volLabels = NSStackView(views: [small("0%"), small("100%"), small("200%")])
        volLabels.distribution = .equalSpacing
        volLabels.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let audioStack = NSStackView(views: audioRadios + [volumeSlider, volLabels])
        audioStack.orientation = .vertical
        audioStack.alignment = .leading
        audioStack.spacing = 8
        let right = NSGridView(views: [[NSTextField(labelWithString: "Audio:"), audioStack]])
        right.rowAlignment = .firstBaseline
        right.column(at: 0).xPlacement = .trailing

        let leftCard = card(), rightCard = card()
        for (c, g) in [(leftCard, left), (rightCard, right)] {
            g.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(g)
            NSLayoutConstraint.activate([
                g.centerXAnchor.constraint(equalTo: c.centerXAnchor),
                g.topAnchor.constraint(equalTo: c.topAnchor, constant: 18),
                g.bottomAnchor.constraint(lessThanOrEqualTo: c.bottomAnchor, constant: -18),
            ])
        }

        trimButton.target = self
        trimButton.action = #selector(beginTrimAction)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        convertButton.target = self
        convertButton.action = #selector(convertAction)
        convertButton.bezelColor = .controlAccentColor
        convertButton.keyEquivalent = "\r"
        estimateLabel.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let bottom = NSStackView()
        bottom.addView(cancel, in: .leading)
        bottom.addView(trimButton, in: .leading)
        bottom.addView(estimateLabel, in: .leading)
        bottom.addView(progress, in: .trailing)
        bottom.addView(convertButton, in: .trailing)

        for v in [playerView, leftCard, rightCard, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: leftCard.topAnchor, constant: -16),
            leftCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            leftCard.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -8),
            rightCard.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 8),
            rightCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            leftCard.heightAnchor.constraint(equalToConstant: 262),
            rightCard.heightAnchor.constraint(equalTo: leftCard.heightAnchor),
            leftCard.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -16),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            bottom.heightAnchor.constraint(equalToConstant: 32),
        ])
        window.contentView = root
    }

    private func small(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    // MARK: Trim

    @objc private func beginTrimAction() { beginTrim() }

    private func beginTrim() {
        guard playerView.canBeginTrimming else { return }
        setTrimming(true)
        playerView.beginTrimming { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setTrimming(false)
                self?.updateEstimate()
            }
        }
    }

    /// Trim must be committed (Trim / Cancel in the bar) before converting.
    private func setTrimming(_ on: Bool) {
        trimButton.isEnabled = !on
        convertButton.isEnabled = !on && !exporting
        convertButton.toolTip = on ? "Press Trim (or Cancel) in the timeline first" : nil
    }

    private var trimRange: CMTimeRange {
        let total = CMTime(seconds: duration, preferredTimescale: 600)
        guard let item = playerView.player?.currentItem else { return CMTimeRange(start: .zero, duration: total) }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : total
        return CMTimeRange(start: start, end: max(end, start + CMTime(value: 1, timescale: 30)))
    }

    // MARK: Dimensions

    private func setupDimensions() {
        let w = sourceSize.width, h = sourceSize.height
        func scaled(_ f: CGFloat) -> CGSize { CGSize(width: (w * f).rounded(), height: (h * f).rounded()) }
        func fitHeight(_ target: CGFloat) -> CGSize? {
            guard min(w, h) > target else { return nil }
            let f = target / min(w, h)
            return scaled(f)
        }
        dimensionPresets = [("\(Int(w)) × \(Int(h))  (Original)", sourceSize), ("75%", scaled(0.75)), ("50%", scaled(0.5)), ("25%", scaled(0.25))]
        for (name, t) in [("1080p", 1080.0), ("720p", 720.0), ("480p", 480.0)] {
            if let s = fitHeight(t) { dimensionPresets.append(("\(name)  (\(Int(s.width)) × \(Int(s.height)))", s)) }
        }
        dimensionPresets.append(("Custom", nil))
        dimensionPopup.removeAllItems()
        dimensionPopup.addItems(withTitles: dimensionPresets.map { p in
            if let s = p.1, !p.0.contains("×") { return "\(p.0)  (\(Int(s.width)) × \(Int(s.height)))" }
            return p.0
        })
        dimensionPopup.selectItem(at: 0)
        setFields(sourceSize)
    }

    private func setFields(_ s: CGSize) {
        widthField.integerValue = Int(s.width)
        heightField.integerValue = Int(s.height)
    }

    @objc private func dimensionChanged() {
        if let s = dimensionPresets[dimensionPopup.indexOfSelectedItem].1 { setFields(s) }
        updateEstimate()
    }

    @objc private func sizeTyped(_ sender: NSTextField) {
        let aspect = sourceSize.width / max(sourceSize.height, 1)
        if sender === widthField {
            heightField.integerValue = Int((CGFloat(widthField.integerValue) / aspect).rounded())
        } else {
            widthField.integerValue = Int((CGFloat(heightField.integerValue) * aspect).rounded())
        }
        dimensionPopup.selectItem(at: dimensionPresets.count - 1)
        updateEstimate()
    }

    private var renderSize: CGSize {
        CGSize(width: max(16, widthField.integerValue), height: max(16, heightField.integerValue))
    }

    // MARK: Quality / audio / estimate

    @objc private func keepQualityChanged() {
        let keep = keepQualityCheck.state == .on
        qualitySlider.isEnabled = !keep
        qualityLabel.textColor = keep ? .tertiaryLabelColor : .secondaryLabelColor
        if keep { codecPopup.selectItem(at: 1) }
        updateEstimate()
    }

    @objc private func qualityChanged() {
        qualityLabel.stringValue = VideoExporter.qualityNames[Int(qualitySlider.integerValue)]
        updateEstimate()
    }

    private var audioMode: VideoExporter.AudioMode {
        VideoExporter.AudioMode(rawValue: audioRadios.first { $0.state == .on }?.tag ?? 0) ?? .keep
    }

    @objc private func audioChanged() {
        volumeSlider.isEnabled = hasAudio && audioMode == .volume
        updateEstimate()
    }

    @objc private func volumeChanged() {
        audioRadios.forEach { $0.state = $0.tag == 3 ? .on : .off }
        volumeSlider.toolTip = "\(Int(volumeSlider.doubleValue * 100))%"
        updateEstimate()
    }

    private func updateEstimate() {
        let secs = CMTimeGetSeconds(trimRange.duration)
        if keepQualityCheck.state == .on {
            estimateLabel.stringValue = "Estimated file size: smaller than original, same quality  ·  \(String(format: "%.1f", secs)) s"
            return
        }
        var bps = VideoExporter.bitrate(size: renderSize, fps: fps, quality: qualitySlider.integerValue)
        if hasAudio && audioMode != .mute { bps += audioMode == .mono ? 96_000 : 160_000 }
        let bytes = Int64(bps * max(secs, 0) / 8)
        let f = ByteCountFormatter()
        f.countStyle = .file
        estimateLabel.stringValue = "Estimated file size: ~\(f.string(fromByteCount: bytes))  ·  \(String(format: "%.1f", secs)) s"
    }

    // MARK: Actions

    @objc private func cancelAction() { window?.close() }

    @objc private func convertAction() {
        guard !exporting else { return }
        exporting = true
        playerView.player?.pause()
        convertButton.isEnabled = false
        progress.isHidden = false
        progress.doubleValue = 0
        let opts = VideoExporter.Options(range: trimRange, renderSize: renderSize, quality: qualitySlider.integerValue,
                                         audio: audioMode, volume: Float(volumeSlider.doubleValue),
                                         codec: codecPopup.indexOfSelectedItem == 1 ? .hevc : .h264,
                                         constantQuality: keepQualityCheck.state == .on ? VideoExporter.losslessLookingQuality : nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DyskShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("edited-\(UUID().uuidString).mp4")
        let asset = self.asset
        let bar = progress
        Task { @MainActor in
            do {
                try await VideoExporter.export(asset: asset, to: out, options: opts) { p in
                    DispatchQueue.main.async { bar.doubleValue = p }
                }
                window?.close()
                onDone(out)
            } catch {
                exporting = false
                convertButton.isEnabled = true
                progress.isHidden = true
                Toast.show("Convert failed: \(error.localizedDescription)", symbol: "xmark.octagon.fill")
            }
        }
    }
}
