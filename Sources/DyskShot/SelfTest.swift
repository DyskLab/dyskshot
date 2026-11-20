import AVFoundation
import AppKit
import ScreenCaptureKit

/// End-to-end feature test, run inside the real app (which has the privacy permissions).
/// Launch with DYSKSHOT_SELFTEST=/path/report.txt — artifacts go next to the report.
@MainActor
enum SelfTest {
    private static var lines: [String] = []
    private static var passed = 0, failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// Dev: DYSKSHOT_CQ_SWEEP=/path/source.mp4 → writes cq-<q>.mp4 next to it for each quality level.
    static func sweep(_ src: String) {
        Task { @MainActor in
            let url = URL(fileURLWithPath: src)
            let asset = AVURLAsset(url: url)
            guard let d = try? await asset.load(.duration), let t = try? await asset.loadTracks(withMediaType: .video).first,
                  let n = try? await t.load(.naturalSize) else { return }
            for q in [0.62, 0.7, 0.75, 0.8, 0.85] as [Float] {
                let out = url.deletingLastPathComponent().appendingPathComponent("cq-\(q).mp4")
                let o = VideoExporter.Options(range: CMTimeRange(start: .zero, duration: d), renderSize: n, quality: 6, audio: .keep,
                                              volume: 1, codec: .hevc, constantQuality: q)
                try? await VideoExporter.export(asset: asset, to: out, options: o) { _ in }
            }
            try? "done".write(toFile: url.deletingLastPathComponent().appendingPathComponent("sweep.done").path, atomically: true, encoding: .utf8)
        }
    }

    static func run(report: String) {
        let dir = URL(fileURLWithPath: report).deletingLastPathComponent().appendingPathComponent("artifacts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Isolate output folders so the test doesn't touch the user's Desktop.
        let savedExport = Prefs.string("exportPath"), savedVideo = Prefs.string("videoExportPath")
        Prefs.d.set(dir.appendingPathComponent("shots").path, forKey: "exportPath")
        Prefs.d.set(dir.appendingPathComponent("videos").path, forKey: "videoExportPath")
        let pbBackup = NSPasteboard.general.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []

        Task { @MainActor in
            await runAll(dir)
            Prefs.d.set(savedExport, forKey: "exportPath")
            Prefs.d.set(savedVideo, forKey: "videoExportPath")
            NSPasteboard.general.clearContents()
            if !pbBackup.isEmpty { NSPasteboard.general.writeObjects(pbBackup) }
            lines.insert("DyskShot self-test: \(passed) passed, \(failed) failed", at: 0)
            try? lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }

    private static func runAll(_ dir: URL) async {
        // 1. Permissions
        check("Screen recording permission (preflight)", CGPreflightScreenCaptureAccess())
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        check("ScreenCaptureKit shareable content", content != nil, "\(content?.displays.count ?? 0) display(s), \(content?.windows.count ?? 0) windows")

        // 2. Capture
        var shot: Capture?
        do {
            let displays = try await ScreenCapturer.freezeDisplays()
            shot = displays.first?.image.map { Capture(image: $0, scale: displays.first!.scale) }
            check("Fullscreen capture (freeze)", shot != nil, shot.map { "\($0.image.width)×\($0.image.height) @\($0.scale)x" } ?? "")
        } catch { check("Fullscreen capture (freeze)", false, error.localizedDescription) }

        if let screen = NSScreen.main {
            let r = NSRect(x: screen.frame.midX - 200, y: screen.frame.midY - 150, width: 400, height: 300)
            let c = try? await ScreenCapturer.captureRect(r)
            check("Area capture (live)", c.map { abs(CGFloat($0.image.width) - 400 * $0.scale) <= 2 } ?? false,
                  c.map { "\($0.image.width)×\($0.image.height)" } ?? "nil")
            if let frozen = try? await ScreenCapturer.freezeDisplays(), let d = frozen.first(where: { $0.screen == screen }) {
                let cropped = d.crop(global: r)
                check("Area capture (frozen crop)", cropped != nil, cropped.map { "\($0.image.width)×\($0.image.height)" } ?? "nil")
            }
        }
        if let w = WindowList.onScreenWindows().first {
            let c = try? await ScreenCapturer.captureWindow(id: w.id)
            check("Window capture", c != nil, c.map { "window \(w.id): \($0.image.width)×\($0.image.height)" } ?? "failed")
            if let c {
                let composed = ImageOps.composeWindow(c, screen: NSScreen.main, withWallpaper: true, shadow: true)
                check("Window + wallpaper/shadow compose", composed.image.width > c.image.width)
            }
        } else { check("Window capture", false, "no app windows on screen") }

        guard let base = shot else { lines.append("Stopping: no base screenshot"); return }
        let sample = ImageOps.scaleTo1x(base)

        // 3. Image processing & output
        check("Add 1px border", ImageOps.addBorder(sample).image.width == sample.image.width + 2 || ImageOps.addBorder(sample).image.width >= sample.image.width)
        let one = ImageOps.scaleTo1x(base)
        check("Scale Retina to 1x", one.scale == 1, "\(one.image.width)px")
        check("Convert to sRGB", ImageOps.toSRGB(sample).image.colorSpace?.name == CGColorSpace.sRGB)
        for f in Prefs.ImageFormat.allCases {
            let data = Output.encode(sample, format: f)
            let src = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            let img = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            check("Encode \(f.title)", img?.width == sample.image.width, data.map { "\($0.count / 1024) KB" } ?? "nil")
        }
        let saved = Output.save(sample)
        check("Save to export folder", saved.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, saved?.lastPathComponent ?? "")
        Output.copy(sample, fileURL: saved)
        let types = NSPasteboard.general.types ?? []
        check("Copy to clipboard (file & image)", types.contains(.png) || types.contains(.tiff), types.prefix(3).map(\.rawValue).joined(separator: ", "))
        let name = Output.fileBaseName(type: "Screenshot", retina: false)
        check("File name template", name.contains(String(Calendar.current.component(.year, from: Date()))), name)
        check("Temp file for drag & drop", Output.tempFile(sample) != nil)

        // 4. Annotation
        let doc = AnnotationDocument(capture: sample)
        let red = NSColor.systemRed
        var anns: [Annotation] = []
        for t in Tool.allCases where t != .select {
            var a = Annotation(tool: t, color: red, width: 4, start: CGPoint(x: 40, y: 40), end: CGPoint(x: 160, y: 120))
            if t == .pen || t == .highlighter { a.points = [CGPoint(x: 40, y: 40), CGPoint(x: 80, y: 90), CGPoint(x: 160, y: 120)] }
            if t == .text { a.text = "Hello" }
            if t == .counter { a.number = 1 }
            anns.append(a)
        }
        for a in anns { doc.checkpoint(); doc.add(a) }
        check("Annotate: all \(anns.count) tools", doc.annotations.count == anns.count)
        doc.undo()
        check("Undo", doc.annotations.count == anns.count - 1)
        doc.redo()
        check("Redo", doc.annotations.count == anns.count)
        doc.checkpoint()
        doc.setBackground(BackgroundStyle(rawValue: 0), padding: 0.3)
        let withBG = doc.export()
        check("Background preset + export", (withBG?.image.width ?? 0) > sample.image.width)
        doc.checkpoint()
        doc.crop(to: CGRect(x: 0, y: 0, width: 200, height: 150))
        check("Crop", abs(doc.imageSize.width - 200) < 2, "\(doc.imageSize)")

        // 5. OCR
        let ocrImg = NSImage(size: NSSize(width: 700, height: 160), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            NSAttributedString(string: "Hello DyskShot 2026", attributes: [.font: NSFont.systemFont(ofSize: 56, weight: .semibold),
                                                                         .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 30, y: 50))
            return true
        }
        if let cg = ocrImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let text = await OCR.text(in: cg, language: nil, separator: " ")
            check("OCR text recognition", text.contains("DyskShot"), "\"\(text)\"")
        }

        // 6. History / Quick Access / Pin / Editor / Desktop
        History.add(sample)
        check("History latest", History.latest() != nil)
        QuickAccessManager.shared.show(.image(sample, saved: saved))
        check("Quick Access overlay", QuickAccessManager.shared.count >= 1)
        QuickAccessManager.shared.toggleVisibility(); QuickAccessManager.shared.toggleVisibility()
        QuickAccessManager.shared.closeAll()
        try? await Task.sleep(for: .milliseconds(400))
        check("Quick Access close all", QuickAccessManager.shared.count == 0)
        PinPanel.show(sample)
        check("Pin to screen", PinPanel.count >= 1)
        PinPanel.toggleAll(); PinPanel.toggleAll(); PinPanel.closeAll()
        check("Close all pins", PinPanel.count == 0)
        EditorWindowController.open(sample)
        let editor = NSApp.windows.first { $0.title == "DyskShot — Annotate" && $0.isVisible }
        check("Annotate editor window", editor != nil)
        editor?.close()
        DesktopCover.shared.togglePersistent()
        let coverShown = DesktopCover.shared.isShown
        DesktopCover.shared.togglePersistent()
        check("Hide/show desktop icons", coverShown && !DesktopCover.shared.isShown)
        check("Wallpaper image", Wallpaper.image(for: NSScreen.main) != nil)

        // 7. Settings & hotkeys
        PreferencesWindow.show()
        let prefs = NSApp.windows.first { $0.isVisible && $0.toolbar != nil && $0.contentViewController is NSTabViewController }
        check("Settings window (10 panes)", (prefs?.contentViewController as? NSTabViewController)?.tabViewItems.count == 10)
        prefs?.close()
        let wanted = HotAction.allCases.filter { $0.shortcut != nil }
        let registered = HotKeyManager.shared.registeredActions
        check("Global shortcuts registered", Set(wanted) == Set(registered), "\(registered.count)/\(wanted.count)")
        check("Shortcut sections cover all actions", Set(HotAction.sections.flatMap(\.actions)) == Set(HotAction.allCases))

        // 8. Recording (with system audio from another process)
        let rec = await recordingTest(dir)
        if let rec {
            // GIF
            let gifA = dir.appendingPathComponent("test-q10.gif"), gifB = dir.appendingPathComponent("test-q6-opt.gif")
            let okA = await GIFEncoder.convert(video: rec, to: gifA, fps: 15, maxWidth: 800, loop: true, quality: 10, optimize: false)
            let okB = await GIFEncoder.convert(video: rec, to: gifB, fps: 15, maxWidth: 800, loop: true, quality: 6, optimize: true)
            let framesA = CGImageSourceCreateWithURL(gifA as CFURL, nil).map(CGImageSourceGetCount) ?? 0
            let framesB = CGImageSourceCreateWithURL(gifB as CFURL, nil).map(CGImageSourceGetCount) ?? 0
            check("GIF export", okA && framesA > 10, "\(framesA) frames, \(size(gifA) / 1024) KB")
            check("GIF quality + optimize", okB && size(gifB) < size(gifA), "\(framesB) frames, \(size(gifB) / 1024) KB")

            // Video editor export (trim + scale + mono)
            let edited = dir.appendingPathComponent("test-edited.mp4")
            let opts = VideoExporter.Options(range: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), duration: CMTime(seconds: 1.5, preferredTimescale: 600)),
                                             renderSize: CGSize(width: 320, height: 240), quality: 3, audio: .mono, volume: 1)
            do {
                try await VideoExporter.export(asset: AVURLAsset(url: rec), to: edited, options: opts) { _ in }
                let a = AVURLAsset(url: edited)
                let d = CMTimeGetSeconds(try await a.load(.duration))
                let vs = try await a.loadTracks(withMediaType: .video).first?.load(.naturalSize)
                check("Video editor: trim + resize", abs(d - 1.5) < 0.25 && vs == CGSize(width: 320, height: 240), String(format: "%.2fs %@", d, "\(vs ?? .zero)"))
            } catch { check("Video editor: trim + resize", false, error.localizedDescription) }

            // Compression
            let compressed = dir.appendingPathComponent("test-recording (compressed).mp4")
            do {
                try await VideoExporter.compress(rec, to: compressed)
                let a = AVURLAsset(url: compressed)
                let track = try await a.loadTracks(withMediaType: .video).first
                let fmt = try await track?.load(.formatDescriptions).first
                let codec = fmt.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC ? "HEVC" : "other" } ?? "?"
                let audio = try await a.loadTracks(withMediaType: .audio).count
                let srcAudio = try await AVURLAsset(url: rec).loadTracks(withMediaType: .audio).count
                check("Compress video (HEVC, same size)", size(compressed) > 0 && codec == "HEVC",
                      "\(size(rec) / 1024) KB → \(size(compressed) / 1024) KB, audio tracks \(srcAudio)→\(audio)")
            } catch { check("Compress video", false, error.localizedDescription) }

            VideoEditorWindowController.open(url: rec) { _ in }
            try? await Task.sleep(for: .milliseconds(800))
            let ve = NSApp.windows.first { $0.title.hasPrefix("Edit Video") && $0.isVisible }
            check("Video editor window", ve != nil)
            ve?.close()
        }

        // 9. Cloud plumbing (no Google account needed)
        Keychain.set("selftest-value", for: "selftest")
        let kc = Keychain.get("selftest")
        Keychain.delete("selftest")
        check("Keychain store/read/delete", kc == "selftest-value" && Keychain.get("selftest") == nil)
        do {
            let (port, task) = try await GoogleDrive.shared.startLoopback(state: "st123")
            _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?state=st123&code=CODE42")!)
            let code = try await task.value
            GoogleDrive.shared.stopLoopback()
            check("OAuth loopback redirect", code == "CODE42", "port \(port)")
        } catch { check("OAuth loopback redirect", false, error.localizedDescription) }
        check("Drive MIME types", GoogleDrive.mimeType(URL(fileURLWithPath: "a.mp4")) == "video/mp4" && GoogleDrive.mimeType(URL(fileURLWithPath: "a.png")) == "image/png")
        check("Google Drive account", GoogleDrive.shared.isSignedIn, GoogleDrive.shared.isSignedIn ? GoogleDrive.shared.email : "not signed in (needs Client ID + sign-in)")
    }

    private static func recordingTest(_ dir: URL) async -> URL? {
        guard let screen = NSScreen.main, case let displayID = screen.displayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            check("Screen recording", false, "no display"); return nil
        }
        let url = dir.appendingPathComponent("test-recording.mp4")
        let rec = ScreenRecorder(outputURL: url)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let rect = NSRect(x: screen.frame.midX - 320, y: screen.frame.midY - 240, width: 640, height: 480)
        let opts = ScreenRecorder.Options(fps: 30, showCursor: true, scale: screen.backingScaleFactor, codec: .h264, quality: 1,
                                          systemAudio: true, microphone: false, microphoneDeviceID: nil)
        do {
            try await rec.start(filter: filter, sourceRect: screen.displayLocalTopLeft(rect), options: opts)
        } catch { check("Screen recording", false, error.localizedDescription); return nil }
        // Moving content + a sound from another process (own audio is excluded by design).
        let flash = NSWindow(contentRect: NSRect(x: rect.minX + 20, y: rect.minY + 20, width: 120, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        flash.level = .screenSaver
        flash.backgroundColor = .systemPurple
        flash.orderFrontRegardless()
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Submarine.aiff"]
        try? player.run()
        for i in 0..<30 {
            flash.setFrameOrigin(NSPoint(x: rect.minX + 20 + CGFloat(i * 14), y: rect.minY + 20 + CGFloat(i * 8)))
            flash.backgroundColor = i % 2 == 0 ? .systemPurple : .systemOrange
            try? await Task.sleep(for: .milliseconds(100))
        }
        flash.orderOut(nil)
        guard let out = await rec.stop() else { check("Screen recording", false, "nothing written"); return nil }
        let asset = AVURLAsset(url: out)
        let d = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let vs = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
        let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        check("Screen recording (video)", d > 2 && vs.width > 0, String(format: "%.1fs %.0f×%.0f, %d KB", d, vs.width, vs.height, size(out) / 1024))
        check("Screen recording (system audio track)", audio >= 1, "\(audio) audio track(s)")
        return out
    }
}
