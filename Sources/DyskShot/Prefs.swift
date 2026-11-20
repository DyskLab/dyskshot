import AppKit

/// All user preferences. UI binds to these keys through NSUserDefaultsController ("values.<key>").
enum Prefs {
    static var d: UserDefaults { .standard }

    static let registered: [String: Any] = [
        // General
        "playSounds": true,
        "shutterSound": 0,
        "showMenuBarIcon": true,
        "exportPath": "", "videoExportPath": "",
        "hideDesktopIcons": false,
        "after.shot.quick": true, "after.shot.copy": false, "after.shot.save": false,
        "after.shot.annotate": false, "after.shot.pin": false, "after.shot.upload": false, "after.rec.upload": false,
        "after.rec.quick": true, "after.rec.copy": false, "after.rec.save": true, "after.rec.open": false, "after.rec.edit": false,
        // Wallpaper
        "wallpaperMode": 0, "customWallpaperPath": "", "plainColor": "#4A5568",
        "windowWithWallpaper": false, "windowPadding": 0.35, "windowShadow": true,
        // Quick Access
        "qa.position": 0, "qa.activeScreen": true, "qa.size": 0.35,
        "qa.autoClose": false, "qa.autoCloseAction": 0, "qa.autoCloseInterval": 1,
        "qa.closeAfterDrag": true, "qa.saveBehavior": 0,
        // Recording
        "rec.showControls": true, "rec.menuBarTime": false, "rec.scale1x": false,
        "rec.showCursor": true, "rec.highlightClicks": false, "rec.showKeystrokes": false,
        "rec.rememberArea": false, "rec.dim": true, "rec.countdown": false,
        "rec.camera": false, "rec.micDevice": "", "rec.cameraDevice": "",
        "rec.fps": 1, "rec.quality": 1, "rec.codec": 0, "rec.systemAudio": false, "rec.mic": false,
        "rec.maxRes": 0, "rec.mono": false, "rec.autoCompress": false,
        "gif.fpsValue": 15, "gif.quality": 8, "gif.optimize": true, "gif.size": 3, "gif.loop": true,
        // Cloud
        "cloud.clientID": "", "cloud.clientSecret": "", "cloud.email": "", "cloud.folderName": "DyskShot", "cloud.folderID": "",
        "cloud.public": true, "cloud.copyLink": true, "cloud.openLink": false,
        // Screenshots
        "shot.format": 0, "shot.scale1x": false, "shot.srgb": false, "shot.border": false,
        "shot.background": 0, "shot.selfTimer": 1, "shot.showCursor": false,
        "shot.freeze": true, "shot.crosshair": 1, "shot.magnifier": true,
        // Annotate
        "ann.invertArrow": false, "ann.smooth": true, "ann.rememberBackground": false,
        "ann.shadow": true, "ann.onTop": false, "ann.dockIcon": true, "ann.lastBackground": 0, "ann.bgPadding": 0.3,
        // Advanced
        "fileNameTemplate": "DyskShot %Y-%m-%d at %H.%M.%S", "askName": false, "retinaSuffix": true,
        "clipboardMode": 0, "pin.rounded": true, "pin.shadow": true, "pin.border": true,
        "historyIndex": 3, "ocr.language": 0, "ocr.lineBreaks": true, "api.enabled": false,
    ]

    static func register() {
        var all = registered
        for a in HotAction.allCases { all["hotkey.\(a.rawValue)"] = a.defaultShortcut?.storage ?? "" }
        d.register(defaults: all)
    }

    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func int(_ k: String) -> Int { d.integer(forKey: k) }
    static func double(_ k: String) -> Double { d.double(forKey: k) }
    static func string(_ k: String) -> String { d.string(forKey: k) ?? "" }

    // MARK: General

    static let shutterSounds = ["Default"] + ["Tink", "Pop", "Glass", "Ping", "Purr", "Bottle", "Frog", "Funk", "Hero", "Morse", "Submarine"]

    static var exportDirectory: URL {
        get {
            let p = string("exportPath")
            if !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { d.set(newValue.path, forKey: "exportPath") }
    }

    /// Recordings folder; empty pref = same as screenshots.
    static var videoDirectory: URL {
        get {
            let p = string("videoExportPath")
            return p.isEmpty ? exportDirectory : URL(fileURLWithPath: p, isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "videoExportPath") }
    }

    static var videoUsesScreenshotFolder: Bool { string("videoExportPath").isEmpty }

    // MARK: Quick Access

    static let qaIntervals = [5, 10, 15, 30, 60]
    static var qaAutoCloseSeconds: Int { qaIntervals[min(max(int("qa.autoCloseInterval"), 0), qaIntervals.count - 1)] }

    // MARK: Recording

    static let recFPSValues = [24, 30, 60]
    static var recFPS: Int { recFPSValues[min(max(int("rec.fps"), 0), 2)] }
    static let maxResValues = [0, 2160, 1440, 1080, 720, 480]
    /// Maximum output height in pixels (0 = original).
    static var recMaxHeight: Int { maxResValues[min(max(int("rec.maxRes"), 0), maxResValues.count - 1)] }
    static var gifFPS: Int { min(max(int("gif.fpsValue"), 5), 30) }
    static let gifSizeValues = [0, 1280, 1024, 800, 640, 480, 320]
    static var gifMaxWidth: Int { gifSizeValues[min(max(int("gif.size"), 0), gifSizeValues.count - 1)] }

    // MARK: Screenshots

    enum ImageFormat: Int, CaseIterable {
        case png, jpeg, heic, tiff
        var title: String { ["PNG", "JPEG", "HEIC", "TIFF"][rawValue] }
        var ext: String { ["png", "jpg", "heic", "tiff"][rawValue] }
        var uti: String { ["public.png", "public.jpeg", "public.heic", "public.tiff"][rawValue] }
    }

    static var imageFormat: ImageFormat { ImageFormat(rawValue: int("shot.format")) ?? .png }
    static let selfTimerValues = [3, 5, 10]
    static var selfTimerSeconds: Int { selfTimerValues[min(max(int("shot.selfTimer"), 0), 2)] }
    static var shotBackground: BackgroundStyle? {
        let i = int("shot.background")
        return i == 0 ? nil : BackgroundStyle(rawValue: i - 1)
    }

    // MARK: Advanced

    static let historyDays = [0, 1, 3, 7, 30]
    static var historyKeepDays: Int { historyDays[min(max(int("historyIndex"), 0), 4)] }

    static var lastArea: NSRect? {
        get { let s = string("lastArea"); return s.isEmpty ? nil : NSRectFromString(s) }
        set { d.set(newValue.map { NSStringFromRect($0) } ?? "", forKey: "lastArea") }
    }

    static var lastRecordArea: NSRect? {
        get { let s = string("lastRecordArea"); return s.isEmpty ? nil : NSRectFromString(s) }
        set { d.set(newValue.map { NSStringFromRect($0) } ?? "", forKey: "lastRecordArea") }
    }

    static var plainColor: NSColor {
        get { NSColor(hex: string("plainColor")) ?? .darkGray }
        set { d.set(newValue.hexString, forKey: "plainColor") }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
