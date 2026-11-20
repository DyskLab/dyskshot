import AVFoundation
import AppKit

/// Dev-only: `DYSKSHOT_RENDER_PREFS=/some/dir` renders Settings panes, the editor and the recording HUD to PNGs.
@MainActor
enum DebugRender {
    static func run(to dir: String) {
        PreferencesWindow.debugRender(to: dir)

        // Sample capture
        let size = NSSize(width: 900, height: 520)
        let img = NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [.systemIndigo, .systemTeal])?.draw(in: r, angle: 30)
            let s = NSAttributedString(string: "DyskShot sample", attributes: [.font: NSFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.white])
            s.draw(at: NSPoint(x: 60, y: 380))
            return true
        }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let capture = Capture(image: cg, scale: CGFloat(cg.width) / size.width)
        EditorWindowController.open(capture)
        if let ed = NSApp.windows.first(where: { $0.title == "DyskShot — Annotate" }),
           let wc = ed.windowController as? EditorWindowController {
            let d = wc.doc
            d.add(Annotation(tool: .arrow, color: .systemRed, width: 6, start: CGPoint(x: 600, y: 120), end: CGPoint(x: 380, y: 300)))
            d.add(Annotation(tool: .rect, color: .systemYellow, width: 4, start: CGPoint(x: 50, y: 360), end: CGPoint(x: 520, y: 450)))
            d.add(Annotation(tool: .spotlight, color: .black, width: 4, start: CGPoint(x: 40, y: 40), end: CGPoint(x: 300, y: 200)))
            var c = Annotation(tool: .counter, color: .systemBlue, width: 4, start: CGPoint(x: 700, y: 400), end: .zero)
            c.number = 1
            d.add(c)
            d.add(Annotation(tool: .arrow, color: .systemGreen, width: 4, start: CGPoint(x: 700, y: 60), end: CGPoint(x: 850, y: 200), arrowStyle: .double))
            d.setBackground(.sunset)
            wc.canvas.documentGeometryChanged()
            ed.setContentSize(NSSize(width: 1180, height: 760))
            ed.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    snapshot(ed.contentView?.superview, to: "\(dir)/editor.png")
                    if let c = d.export(), let data = Output.encode(c, format: .png) {
                        try? data.write(to: URL(fileURLWithPath: "\(dir)/editor-export.png"))
                    }
                }
            }
        }

        // Video editor (needs a sample video path in DYSKSHOT_SAMPLE_VIDEO)
        if let p = ProcessInfo.processInfo.environment["DYSKSHOT_SAMPLE_VIDEO"] {
            VideoEditorWindowController.open(url: URL(fileURLWithPath: p)) { _ in }
            let opts = VideoExporter.Options(range: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600)),
                                             renderSize: CGSize(width: 640, height: 360), quality: 3, audio: .mono, volume: 1)
            Task {
                do {
                    try await VideoExporter.export(asset: AVURLAsset(url: URL(fileURLWithPath: p)), to: URL(fileURLWithPath: "\(dir)/export-test.mp4"), options: opts) { _ in }
                } catch { try? "\(error)".write(toFile: "\(dir)/export-error.txt", atomically: true, encoding: .utf8) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated {
                    let w = NSApp.windows.first { $0.title.hasPrefix("Edit Video") }
                    snapshot(w?.contentView, to: "\(dir)/video-editor.png")
                }
            }
        }

        // Recording controls pill
        if let screen = NSScreen.main {
            let rc = RecordingControls(around: NSRect(x: 300, y: 400, width: 600, height: 300), on: screen)
            rc.update(elapsed: 754)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    snapshot(rc.debugView, to: "\(dir)/rec-controls.png")
                    rc.close()
                }
            }
        }

        // Recording HUD
        if let screen = NSScreen.main {
            let ctrl = RecordSetupController(rect: NSRect(x: 200, y: 300, width: 800, height: 400), screen: screen,
                                             reselect: {}, completion: { _, _ in })
            let hud = RecordHUD(controller: ctrl)
            hud.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    snapshot(hud.contentView, to: "\(dir)/hud.png")
                    hud.orderOut(nil)
                }
            }
        }
    }

    static func snapshot(_ v: NSView?, to path: String) {
        guard let v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        if v.window?.appearance?.name == .darkAqua { v.appearance = NSAppearance(named: .darkAqua) }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
