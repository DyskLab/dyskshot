import AppKit

@MainActor
final class CaptureController {
    static let shared = CaptureController()

    enum Mode { case area, previousArea, window, fullscreen, ocr, selfTimer }
    /// One-off action that replaces the "After capture" prefs (from "Capture Area & …" shortcuts).
    enum AfterAction { case copy, save, upload, annotate, pin }
    private var pendingAfter: AfterAction?

    private var overlay: SelectionOverlayController?
    private var busy = false

    // MARK: Sound

    static func playShutter() {
        guard Prefs.bool("playSounds") else { return }
        let i = Prefs.int("shutterSound")
        let sound: NSSound?
        if i <= 0 || i >= Prefs.shutterSounds.count {
            sound = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true) ?? NSSound(named: "Tink")
        } else {
            sound = NSSound(named: Prefs.shutterSounds[i])
        }
        sound?.play()
    }

    // MARK: Entry

    func start(_ mode: Mode, after: AfterAction? = nil) {
        guard overlay == nil, !busy, !RecordingController.shared.isRecording, Self.ensurePermission() else { return }
        busy = true
        pendingAfter = after
        Task { @MainActor in
            await DesktopCover.shared.beginCapture()
            do {
                try await run(mode)
            } catch {
                DesktopCover.shared.endCapture()
                Toast.show("Capture failed: \(error.localizedDescription)", symbol: "xmark.octagon.fill")
            }
            busy = false
        }
    }

    private func run(_ mode: Mode) async throws {
        switch mode {
        case .fullscreen:
            let displays = try await ScreenCapturer.freezeDisplays(showCursor: Prefs.bool("shot.showCursor"))
            DesktopCover.shared.endCapture()
            let screen = NSScreen.underMouse
            guard let d = displays.first(where: { $0.screen == screen }) ?? displays.first, let img = d.image else { return }
            finishScreenshot(Capture(image: img, scale: d.scale))

        case .previousArea:
            guard let rect = Prefs.lastArea, let screen = NSScreen.containing(rect) else {
                DesktopCover.shared.endCapture()
                Toast.show("No previous area yet", symbol: "exclamationmark.triangle.fill")
                return
            }
            let displays = try await ScreenCapturer.freezeDisplays()
            DesktopCover.shared.endCapture()
            if let c = displays.first(where: { $0.screen == screen })?.crop(global: rect) { finishScreenshot(c) }

        case .area, .window, .ocr:
            let frozen = Prefs.bool("shot.freeze")
            let displays = frozen ? try await ScreenCapturer.freezeDisplays()
                                  : NSScreen.screens.map { OverlayDisplay(screen: $0, image: nil) }
            var opts = SelectionOptions(windowMode: mode == .window)
            if mode == .ocr { opts.hint = "Select text to recognize · Space: window mode · Esc: cancel" }
            present(displays: displays, options: opts) { [weak self] result in
                self?.handleSelection(result, ocr: mode == .ocr, frozen: frozen)
            }

        case .selfTimer:
            DesktopCover.shared.endCapture()
            var opts = SelectionOptions(allowsScreen: true)
            opts.hint = "Self-timer: drag an area, or click for the whole screen · Esc: cancel"
            present(displays: NSScreen.screens.map { OverlayDisplay(screen: $0, image: nil) }, options: opts) { [weak self] result in
                self?.handleSelfTimer(result)
            }
        }
    }

    private func present(displays: [OverlayDisplay], options: SelectionOptions,
                         completion: @escaping (SelectionResult) -> Void) {
        let ctrl = SelectionOverlayController(displays: displays, windows: WindowList.onScreenWindows(), options: options) { result in
            self.overlay = nil
            completion(result)
        }
        overlay = ctrl
        ctrl.show()
    }

    // MARK: Results

    private func handleSelection(_ result: SelectionResult, ocr: Bool, frozen: Bool) {
        let flags = NSEvent.modifierFlags
        Task { @MainActor in
            defer { DesktopCover.shared.endCapture() }
            var capture: Capture?
            var isWindow = false
            var screen: NSScreen?
            switch result {
            case .cancelled:
                return
            case .screen(let d):
                screen = d.screen
                capture = d.image.map { Capture(image: $0, scale: d.scale) }
            case .area(let rect, let d):
                Prefs.lastArea = rect
                screen = d.screen
                if frozen {
                    capture = d.crop(global: rect)
                } else {
                    capture = try? await ScreenCapturer.captureRect(rect)
                }
            case .window(let id, let rect, let d):
                screen = d.screen
                isWindow = true
                capture = try? await ScreenCapturer.captureWindow(id: id)
                if capture == nil {
                    if frozen {
                        capture = d.crop(global: rect)
                    } else {
                        capture = try? await ScreenCapturer.captureRect(rect)
                    }
                }
            }
            guard var c = capture else { return }
            if ocr { OCR.recognize(c); return }
            if isWindow {
                c = ImageOps.composeWindow(c, screen: screen,
                                           withWallpaper: Prefs.bool("windowWithWallpaper") != flags.contains(.shift),
                                           shadow: Prefs.bool("windowShadow") && !flags.contains(.option))
            }
            finishScreenshot(c, skipBackground: isWindow || flags.contains(.shift))
        }
    }

    private func handleSelfTimer(_ result: SelectionResult) {
        let rect: NSRect
        switch result {
        case .area(let r, _): rect = r
        case .screen(let d): rect = d.screen.frame
        case .window(_, let r, _): rect = r
        case .cancelled: return
        }
        Countdown.run(seconds: Prefs.selfTimerSeconds, on: NSScreen.containing(rect)) {
            Task { @MainActor in
                await DesktopCover.shared.beginCapture()
                defer { DesktopCover.shared.endCapture() }
                if let c = try? await ScreenCapturer.captureRect(rect, showCursor: Prefs.bool("shot.showCursor")) {
                    self.finishScreenshot(c)
                }
            }
        }
    }

    // MARK: Pipeline

    func finishScreenshot(_ capture: Capture, skipBackground: Bool = false) {
        var c = capture
        if !skipBackground, let bg = Prefs.shotBackground {
            let doc = AnnotationDocument(capture: c)
            doc.background = bg
            c = doc.export() ?? c
        }
        if Prefs.bool("shot.border") { c = ImageOps.addBorder(c) }
        if Prefs.bool("shot.scale1x") { c = ImageOps.scaleTo1x(c) }
        if Prefs.bool("shot.srgb") { c = ImageOps.toSRGB(c) }
        History.add(c)
        deliver(c)
    }

    /// Runs the "After capture → Screenshot" actions.
    func deliver(_ c: Capture) {
        Self.playShutter()
        if let after = pendingAfter {
            pendingAfter = nil
            switch after {
            case .copy: Output.copy(c, fileURL: nil); Toast.show("Copied to clipboard")
            case .save: if let url = Output.save(c) { Toast.show("Saved \(url.lastPathComponent)") }
            case .upload: Cloud.upload(c)
            case .annotate: EditorWindowController.open(c)
            case .pin: PinPanel.show(c)
            }
            return
        }
        var quick = Prefs.bool("after.shot.quick")
        let copy = Prefs.bool("after.shot.copy"), save = Prefs.bool("after.shot.save")
        let annotate = Prefs.bool("after.shot.annotate"), pin = Prefs.bool("after.shot.pin")
        let upload = Prefs.bool("after.shot.upload")
        if !(quick || copy || save || annotate || pin || upload) { quick = true }

        var saved: URL?
        if save { saved = Output.save(c) }
        if copy { Output.copy(c, fileURL: saved) }
        if annotate { EditorWindowController.open(c) }
        if pin { PinPanel.show(c) }
        if upload { if let saved { Cloud.upload(file: saved) } else { Cloud.upload(c) } }
        if quick { QuickAccessManager.shared.show(.image(c, saved: saved)) }
        if !quick, let saved { Toast.show("Saved \(saved.lastPathComponent)") } else if !quick && copy { Toast.show("Copied to clipboard") }
    }

    // MARK: Permission

    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let askedBefore = UserDefaults.standard.bool(forKey: "askedScreenPermission")
        UserDefaults.standard.set(true, forKey: "askedScreenPermission")
        if CGRequestScreenCaptureAccess() { return true }
        guard askedBefore else { return false }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Enable DyskShot in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch DyskShot.\n\nIf it is already enabled but this keeps appearing, remove DyskShot from the list with the − button and enable it again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch DyskShot")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
        return false
    }

    /// macOS only applies a new Screen Recording grant after the app restarts.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Countdown HUD (self-timer, recording)

@MainActor
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen?, completion: @escaping @MainActor () -> Void) {
        guard seconds > 0 else { completion(); return }
        let screen = screen ?? NSScreen.screens[0]
        let size = NSSize(width: 140, height: 140)
        let panel = NSPanel(contentRect: NSRect(x: screen.frame.midX - 70, y: screen.frame.midY - 70, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 28
        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 22, width: size.width, height: 90)
        effect.addSubview(label)
        panel.contentView = effect
        panel.orderFrontRegardless()

        var remaining = seconds
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    panel.orderOut(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { MainActor.assumeIsolated { completion() } }
                } else {
                    label.stringValue = "\(remaining)"
                    NSSound(named: "Tink")?.play()
                }
            }
        }
    }
}

// MARK: - Hide desktop icons (wallpaper cover windows above the icon layer)

@MainActor
final class DesktopCover {
    static let shared = DesktopCover()
    private var windows: [NSWindow] = []
    private var persistent = false
    private var captureActive = false

    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }
    var isShown: Bool { !windows.isEmpty }

    func beginCapture() async {
        guard Prefs.bool("hideDesktopIcons"), !isShown else { return }
        captureActive = true
        show()
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    func endCapture() {
        guard captureActive else { return }
        captureActive = false
        if !persistent { hide() }
    }

    func togglePersistent() {
        persistent.toggle()
        if persistent { show() } else { hide() }
        Toast.show(persistent ? "Desktop icons hidden" : "Desktop icons visible", symbol: "menubar.dock.rectangle")
    }

    private func show() {
        hide()
        let level = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: level)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.hasShadow = false
            let v = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.imageScaling = .scaleAxesIndependently
            v.wantsLayer = true
            v.layer?.backgroundColor = Prefs.plainColor.cgColor
            if let img = Wallpaper.image(for: screen) {
                v.layer?.contents = img
                v.layer?.contentsGravity = .resizeAspectFill
            }
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    private func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
