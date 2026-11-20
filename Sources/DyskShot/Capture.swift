import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A captured image plus its pixel density (2.0 on Retina).
struct Capture {
    let image: CGImage
    let scale: CGFloat

    var pointSize: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    static func load(from url: URL) -> Capture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return Capture(image: img, scale: max(1, CGFloat(dpi / 72).rounded()))
    }
}

/// A display shown by the selection overlay. `image` is nil when the screen is not frozen.
struct OverlayDisplay {
    let screen: NSScreen
    let image: CGImage?
    var scale: CGFloat { image.map { CGFloat($0.width) / screen.frame.width } ?? screen.backingScaleFactor }

    /// Crop a rect given in global Cocoa coordinates.
    func crop(global r: NSRect) -> Capture? {
        guard let image else { return nil }
        let local = r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(
            NSRect(origin: .zero, size: screen.frame.size))
        guard !local.isEmpty else { return nil }
        let s = scale
        let px = CGRect(x: local.minX * s, y: (screen.frame.height - local.maxY) * s,
                        width: local.width * s, height: local.height * s).integral
        guard let c = image.cropping(to: px) else { return nil }
        return Capture(image: c, scale: s)
    }
}

struct WindowInfo {
    let id: CGWindowID
    /// Global Cocoa coordinates (bottom-left origin).
    let frame: CGRect
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static var underMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }

    static func containing(_ r: NSRect) -> NSScreen? {
        let c = NSPoint(x: r.midX, y: r.midY)
        return screens.first { NSMouseInRect(c, $0.frame, false) } ?? screens.max {
            $0.frame.intersection(r).width * $0.frame.intersection(r).height <
                $1.frame.intersection(r).width * $1.frame.intersection(r).height
        }
    }

    /// Converts a global Cocoa rect to this display's top-left-origin coordinates (ScreenCaptureKit space).
    func displayLocalTopLeft(_ r: NSRect) -> CGRect {
        let local = r.offsetBy(dx: -frame.minX, dy: -frame.minY)
        return CGRect(x: local.minX, y: frame.height - local.maxY, width: local.width, height: local.height)
    }
}

// MARK: - ScreenCaptureKit

@MainActor
enum ScreenCapturer {
    /// Our windows that must stay out of captures (everything except the desktop-icon cover).
    static func ownWindowsToExclude(_ content: SCShareableContent, keep: Set<CGWindowID> = []) -> [SCWindow] {
        let keepIDs = keep.union(DesktopCover.shared.windowIDs)
        return content.windows.filter { $0.owningApplication?.processID == getpid() && !keepIDs.contains($0.windowID) }
    }

    static func freezeDisplays(showCursor: Bool = false) async throws -> [OverlayDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let exclude = ownWindowsToExclude(content)
        var result: [OverlayDisplay] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: exclude)
            let config = SCStreamConfiguration()
            let s = screen.backingScaleFactor
            config.width = Int(screen.frame.width * s)
            config.height = Int(screen.frame.height * s)
            config.showsCursor = showCursor
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(OverlayDisplay(screen: screen, image: image))
        }
        return result
    }

    /// Live capture of a global rect (used when the screen isn't frozen).
    static func captureRect(_ r: NSRect, showCursor: Bool = false) async throws -> Capture? {
        guard let screen = NSScreen.containing(r) else { return nil }
        let displays = try await freezeDisplays(showCursor: showCursor)
        return displays.first { $0.screen == screen }?.crop(global: r)
    }

    /// Capture a single window on its own, with transparent corners and no shadow.
    static func captureWindow(id: CGWindowID) async throws -> Capture? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Capture(image: image, scale: scale)
    }
}

enum WindowList {
    /// Normal app windows, front to back.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let myPID = getpid()
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha == 0 { return nil }
            if r.width < 40 || r.height < 40 { return nil }
            let cocoa = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            return WindowInfo(id: number, frame: cocoa)
        }
    }
}

// MARK: - Image post-processing

enum ImageOps {
    static func context(width: Int, height: Int, space: CGColorSpace? = nil) -> CGContext? {
        let cs = space ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func addBorder(_ c: Capture) -> Capture {
        guard let ctx = context(width: c.image.width, height: c.image.height, space: c.image.colorSpace) else { return c }
        let r = CGRect(x: 0, y: 0, width: c.image.width, height: c.image.height)
        ctx.draw(c.image, in: r)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.25).cgColor)
        ctx.setLineWidth(c.scale)
        ctx.stroke(r.insetBy(dx: c.scale / 2, dy: c.scale / 2))
        return ctx.makeImage().map { Capture(image: $0, scale: c.scale) } ?? c
    }

    static func scaleTo1x(_ c: Capture) -> Capture {
        guard c.scale > 1 else { return c }
        let w = max(1, Int((CGFloat(c.image.width) / c.scale).rounded()))
        let h = max(1, Int((CGFloat(c.image.height) / c.scale).rounded()))
        guard let ctx = context(width: w, height: h, space: c.image.colorSpace) else { return c }
        ctx.interpolationQuality = .high
        ctx.draw(c.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().map { Capture(image: $0, scale: 1) } ?? c
    }

    static func toSRGB(_ c: Capture) -> Capture {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let img = c.image.copy(colorSpace: srgb) ?? redraw(c.image, in: srgb) else { return c }
        return Capture(image: img, scale: c.scale)
    }

    private static func redraw(_ img: CGImage, in space: CGColorSpace) -> CGImage? {
        guard let ctx = context(width: img.width, height: img.height, space: space) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    /// Window capture → optional wallpaper background, padding and drop shadow.
    @MainActor
    static func composeWindow(_ c: Capture, screen: NSScreen?, withWallpaper: Bool, shadow: Bool) -> Capture {
        guard withWallpaper || shadow else { return c }
        let s = c.scale
        let size = c.pointSize
        let pad: CGFloat = withWallpaper ? (24 + CGFloat(Prefs.double("windowPadding")) * 136).rounded() : 56
        let canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        guard let ctx = context(width: Int(canvas.width * s), height: Int(canvas.height * s)) else { return c }
        let full = CGRect(x: 0, y: 0, width: canvas.width * s, height: canvas.height * s)
        if withWallpaper { Wallpaper.draw(in: ctx, rect: full, screen: screen) }
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 40 * s,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
        }
        ctx.draw(c.image, in: CGRect(x: pad * s, y: pad * s, width: CGFloat(c.image.width), height: CGFloat(c.image.height)))
        return ctx.makeImage().map { Capture(image: $0, scale: s) } ?? c
    }
}

// MARK: - Wallpaper source (desktop / custom / plain color)

@MainActor
enum Wallpaper {
    static func image(for screen: NSScreen?) -> NSImage? {
        switch Prefs.int("wallpaperMode") {
        case 1:
            let p = Prefs.string("customWallpaperPath")
            return p.isEmpty ? nil : NSImage(contentsOfFile: p)
        case 2:
            return nil
        default:
            guard let screen = screen ?? NSScreen.main,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return NSImage(contentsOf: url)
        }
    }

    /// Aspect-fill the wallpaper (or plain color) into rect.
    static func draw(in ctx: CGContext, rect: CGRect, screen: NSScreen?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(Prefs.plainColor.cgColor)
        ctx.fill(rect)
        guard let img = image(for: screen), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let r = max(rect.width / iw, rect.height / ih)
        let dw = iw * r, dh = ih * r
        ctx.interpolationQuality = .high
        ctx.clip(to: rect)
        ctx.draw(cg, in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
    }
}

// MARK: - Output (clipboard / disk)

@MainActor
enum Output {
    static func encode(_ c: Capture, format: Prefs.ImageFormat = Prefs.imageFormat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.uti as CFString, 1, nil) else { return nil }
        let dpi = 72 * c.scale
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg || format == .heic { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, c.image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Copy according to the "Copy to clipboard" preference (file & image / image / file).
    static func copy(_ c: Capture, fileURL: URL? = nil) {
        let mode = Prefs.int("clipboardMode")
        let item = NSPasteboardItem()
        if mode != 2 {
            if let png = encode(c, format: .png) { item.setData(png, forType: .png) }
            if let tiff = c.nsImage.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        if mode != 1, let url = fileURL ?? tempFile(c) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    /// Save into the export folder (or ask for a location). Returns nil if cancelled/failed.
    @discardableResult
    static func save(_ c: Capture, ask: Bool = false) -> URL? {
        let format = Prefs.imageFormat
        let base = fileBaseName(type: "Screenshot", retina: c.scale > 1)
        guard let url = destination(base: base, ext: format.ext, dir: Prefs.exportDirectory, ask: ask) else { return nil }
        guard let data = encode(c, format: format), (try? data.write(to: url)) != nil else {
            Toast.show("Save failed", symbol: "xmark.octagon.fill")
            return nil
        }
        return url
    }

    /// Copy an existing file (recording/GIF) into the recordings folder.
    static func saveFile(_ src: URL, type: String, ask: Bool = false) -> URL? {
        let base = fileBaseName(type: type, retina: false)
        guard let url = destination(base: base, ext: src.pathExtension, dir: Prefs.videoDirectory, ask: ask) else { return nil }
        do {
            try FileManager.default.copyItem(at: src, to: url)
            return url
        } catch {
            Toast.show("Save failed", symbol: "xmark.octagon.fill")
            return nil
        }
    }

    private static func destination(base: String, ext: String, dir: URL, ask: Bool) -> URL? {
        var name = base
        if ask {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(base).\(ext)"
            panel.directoryURL = dir
            NSApp.activate()
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
        if Prefs.bool("askName") {
            guard let n = askForName(base) else { return nil }
            name = n
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return uniqueURL(in: dir, base: name, ext: ext)
    }

    private static func askForName(_ base: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Name your capture"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = base
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let n = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return n.isEmpty ? base : n
    }

    /// Temp file used for drag & drop / clipboard.
    static func tempFile(_ c: Capture) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DyskShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = Prefs.imageFormat
        let url = uniqueURL(in: dir, base: fileBaseName(type: "Screenshot", retina: c.scale > 1), ext: format.ext)
        guard let data = encode(c, format: format), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// Template tokens: %Y %m %d %H %M %S %t (type).
    static func fileBaseName(type: String, retina: Bool) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        func p(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        var s = Prefs.string("fileNameTemplate")
        if s.isEmpty { s = "DyskShot %Y-%m-%d at %H.%M.%S" }
        s = s.replacingOccurrences(of: "%Y", with: String(comps.year ?? 0))
            .replacingOccurrences(of: "%m", with: p(comps.month))
            .replacingOccurrences(of: "%d", with: p(comps.day))
            .replacingOccurrences(of: "%H", with: p(comps.hour))
            .replacingOccurrences(of: "%M", with: p(comps.minute))
            .replacingOccurrences(of: "%S", with: p(comps.second))
            .replacingOccurrences(of: "%t", with: type)
            .replacingOccurrences(of: "/", with: "-")
        if retina && Prefs.bool("retinaSuffix") { s += "@2x" }
        return s
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
