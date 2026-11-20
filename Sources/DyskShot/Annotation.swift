import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum Tool: Int, CaseIterable {
    case select, rect, filledRect, ellipse, line, arrow, text, pixelate, spotlight, counter, pen, highlighter

    var name: String {
        switch self {
        case .select: "Select & Move"
        case .rect: "Rectangle"
        case .filledRect: "Filled Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .pixelate: "Pixelate"
        case .spotlight: "Spotlight"
        case .counter: "Counter"
        case .pen: "Pencil"
        case .highlighter: "Highlighter"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rect: "square"
        case .filledRect: "square.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.down.left"
        case .text: "textformat"
        case .pixelate: "checkerboard.rectangle"
        case .spotlight: "rectangle.inset.filled"
        case .counter: "1.circle.fill"
        case .pen: "pencil"
        case .highlighter: "highlighter"
        }
    }

    var shortcut: String {
        switch self {
        case .select: "v"
        case .rect: "r"
        case .filledRect: "f"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .pixelate: "b"
        case .spotlight: "s"
        case .counter: "n"
        case .pen: "p"
        case .highlighter: "h"
        }
    }
}

enum ArrowStyle: Int, CaseIterable {
    case tapered, classic, double, open
    var name: String { ["Tapered", "Classic", "Double-headed", "Open head"][rawValue] }
}

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 0
    var reversed = false
    var arrowStyle: ArrowStyle = .tapered

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isMeaningful: Bool {
        switch tool {
        case .select: return false
        case .pen, .highlighter: return points.count > 1
        case .text: return !text.isEmpty
        case .counter: return true
        case .line, .arrow: return hypot(end.x - start.x, end.y - start.y) > 3
        case .rect, .filledRect, .ellipse, .pixelate, .spotlight: return rect.width > 2 && rect.height > 2
        }
    }

    /// Bounding box used for selection.
    var bounds: CGRect {
        switch tool {
        case .pen, .highlighter:
            guard let f = points.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -width * 2, dy: -width * 2)
        case .text:
            let size = NSAttributedString(string: text, attributes: Renderer.textAttributes(color: color, width: width)).size()
            return CGRect(x: start.x, y: start.y - size.height / 2, width: size.width, height: size.height)
        case .counter:
            let d = Renderer.counterDiameter(for: width)
            return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        case .line, .arrow:
            return rect.insetBy(dx: -width * 2, dy: -width * 2)
        default:
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    func hitTest(_ p: CGPoint) -> Bool {
        let tol = max(6, width)
        switch tool {
        case .line, .arrow:
            return Self.distance(p, start, end) <= tol
        case .pen, .highlighter:
            return zip(points, points.dropFirst()).contains { Self.distance(p, $0, $1) <= tol + (tool == .highlighter ? width * 2 : 0) }
        case .rect, .ellipse:
            let outer = rect.insetBy(dx: -tol, dy: -tol), inner = rect.insetBy(dx: tol, dy: tol)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        default:
            return bounds.insetBy(dx: -3, dy: -3).contains(p)
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

enum BackgroundStyle: Int, CaseIterable {
    case ocean, sunset, candy, forest, midnight, peach, plain

    var name: String {
        ["Ocean", "Sunset", "Candy", "Forest", "Midnight", "Peach", "Plain"][rawValue]
    }

    var colors: [NSColor] {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .ocean: return [c(0x4FACFE), c(0x00F2FE)]
        case .sunset: return [c(0xFA709A), c(0xFEE140)]
        case .candy: return [c(0xA18CD1), c(0xFBC2EB)]
        case .forest: return [c(0x43E97B), c(0x38F9D7)]
        case .midnight: return [c(0x232526), c(0x414345)]
        case .peach: return [c(0xFFECD2), c(0xFCB69F)]
        case .plain: return [c(0xE9ECEF), c(0xE9ECEF)]
        }
    }

    func swatch(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            NSGradient(colors: colors)?.draw(in: NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6), angle: -45)
            return true
        }
    }
}

final class AnnotationDocument {
    struct State {
        var capture: Capture
        var annotations: [Annotation] = []
        var background: BackgroundStyle?
        var padding: CGFloat = 0.3
    }

    private(set) var state: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var pixelCache: (ObjectIdentifier, CGImage?)?

    init(capture: Capture) { state = State(capture: capture) }

    var capture: Capture { state.capture }
    var annotations: [Annotation] { state.annotations }
    var background: BackgroundStyle? {
        get { state.background }
        set { state.background = newValue }
    }
    var paddingFactor: CGFloat {
        get { state.padding }
        set { state.padding = newValue }
    }

    var imageSize: CGSize { capture.pointSize }
    var padding: CGFloat {
        guard background != nil else { return 0 }
        let base = min(imageSize.width, imageSize.height)
        return (max(16, base * 0.03) + paddingFactor * max(80, base * 0.25)).rounded()
    }
    var canvasSize: CGSize {
        CGSize(width: imageSize.width + padding * 2, height: imageSize.height + padding * 2)
    }
    var nextCounter: Int { annotations.filter { $0.tool == .counter }.count + 1 }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var pixelated: CGImage? {
        let id = ObjectIdentifier(capture.image)
        if let cache = pixelCache, cache.0 == id { return cache.1 }
        let img = Self.pixelate(capture)
        pixelCache = (id, img)
        return img
    }

    // MARK: Mutations (call checkpoint() first for undo)

    func checkpoint() {
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func add(_ a: Annotation) {
        checkpoint()
        state.annotations.append(a)
    }

    func replace(at i: Int, with a: Annotation) {
        guard state.annotations.indices.contains(i) else { return }
        state.annotations[i] = a
    }

    func remove(at i: Int) {
        guard state.annotations.indices.contains(i) else { return }
        checkpoint()
        state.annotations.remove(at: i)
    }

    func setBackground(_ bg: BackgroundStyle?, padding: CGFloat? = nil) {
        checkpoint()
        state.background = bg
        if let padding { state.padding = padding }
    }

    /// Crop to a rect in image coordinates (points, bottom-left origin).
    func crop(to r: CGRect) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let rect = r.intersection(bounds).integral
        guard rect.width >= 4, rect.height >= 4, rect != bounds else { return }
        let s = capture.scale
        let px = CGRect(x: rect.minX * s, y: (imageSize.height - rect.maxY) * s, width: rect.width * s, height: rect.height * s).integral
        guard let img = capture.image.cropping(to: px) else { return }
        checkpoint()
        state.capture = Capture(image: img, scale: s)
        state.annotations = state.annotations.map { var a = $0; a.translate(dx: -rect.minX, dy: -rect.minY); return a }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    func hitTest(_ p: CGPoint) -> Int? {
        annotations.indices.reversed().first { annotations[$0].hitTest(p) }
    }

    private static func pixelate(_ c: Capture) -> CGImage? {
        let ci = CIImage(cgImage: c.image)
        let f = CIFilter.pixellate()
        f.inputImage = ci.clampedToExtent()
        f.scale = Float(max(8, 7 * c.scale))
        f.center = .zero
        guard let out = f.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }

    /// Flatten image + background + annotations into a new capture.
    func export() -> Capture? {
        let scale = capture.scale
        let size = canvasSize
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        let space = capture.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        Renderer.draw(self, in: ctx, inProgress: nil, shadowScale: scale)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return Capture(image: img, scale: scale)
    }
}

enum Renderer {
    static func fontSize(for width: CGFloat) -> CGFloat { 12 + width * 3 }
    static func counterDiameter(for width: CGFloat) -> CGFloat { max(24, 16 + width * 3) }

    /// Draws in canvas coordinates (points, bottom-left origin). Requires NSGraphicsContext.current == ctx.
    /// `shadowScale` compensates for CG shadows ignoring the CTM (1 on screen, capture scale on export).
    static func draw(_ doc: AnnotationDocument, in ctx: CGContext, inProgress: Annotation?, shadowScale: CGFloat = 1) {
        let canvas = CGRect(origin: .zero, size: doc.canvasSize)
        let pad = doc.padding
        let imgRect = CGRect(origin: .zero, size: doc.imageSize)

        if let bg = doc.background {
            NSGradient(colors: bg.colors)?.draw(in: canvas, angle: -45)
        }

        ctx.saveGState()
        ctx.translateBy(x: pad, y: pad)

        if doc.background != nil {
            let path = CGPath(roundedRect: imgRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * shadowScale), blur: 30 * shadowScale,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(doc.capture.image, in: imgRect)
            ctx.restoreGState()
        } else {
            ctx.draw(doc.capture.image, in: imgRect)
        }

        var all = doc.annotations
        if let a = inProgress { all.append(a) }

        // Spotlights first: dim everything outside all spotlight rects.
        let spots = all.filter { $0.tool == .spotlight }.map(\.rect)
        if !spots.isEmpty {
            let path = NSBezierPath(rect: imgRect)
            for r in spots { path.append(NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)) }
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            path.fill()
        }

        for a in all where a.tool != .spotlight { draw(a, in: ctx, doc: doc, imgRect: imgRect, shadowScale: shadowScale) }
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, in ctx: CGContext, doc: AnnotationDocument, imgRect: CGRect, shadowScale: CGFloat = 1) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        a.color.setStroke()
        a.color.setFill()
        if Prefs.bool("ann.shadow"), ![.pixelate, .highlighter, .text, .counter, .spotlight].contains(a.tool) {
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * shadowScale), blur: 4 * shadowScale,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }

        switch a.tool {
        case .select, .spotlight:
            break

        case .pixelate:
            guard let p = doc.pixelated else { return }
            ctx.clip(to: a.rect.intersection(imgRect))
            ctx.draw(p, in: imgRect)

        case .rect:
            let path = NSBezierPath(roundedRect: a.rect, xRadius: 3, yRadius: 3)
            path.lineWidth = a.width
            path.stroke()

        case .filledRect:
            NSBezierPath(roundedRect: a.rect, xRadius: 3, yRadius: 3).fill()

        case .ellipse:
            let path = NSBezierPath(ovalIn: a.rect)
            path.lineWidth = a.width
            path.stroke()

        case .line:
            let path = NSBezierPath()
            path.move(to: a.start)
            path.line(to: a.end)
            path.lineWidth = a.width
            path.lineCapStyle = .round
            path.stroke()

        case .arrow:
            let (s, e) = a.reversed ? (a.end, a.start) : (a.start, a.end)
            drawArrow(from: s, to: e, width: a.width, style: a.arrowStyle)

        case .pen, .highlighter:
            guard let first = a.points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            if Prefs.bool("ann.smooth"), a.points.count > 2 {
                for i in 1..<(a.points.count - 1) {
                    let p = a.points[i], n = a.points[i + 1]
                    path.curve(to: CGPoint(x: (p.x + n.x) / 2, y: (p.y + n.y) / 2), controlPoint: p)
                }
                path.line(to: a.points[a.points.count - 1])
            } else {
                for p in a.points.dropFirst() { path.line(to: p) }
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if a.tool == .highlighter {
                ctx.setBlendMode(.multiply)
                a.color.withAlphaComponent(0.45).setStroke()
                path.lineWidth = a.width * 4 + 6
                path.lineCapStyle = .square
            } else {
                path.lineWidth = a.width
            }
            path.stroke()

        case .text:
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            let str = NSAttributedString(string: a.text, attributes: textAttributes(color: a.color, width: a.width, shadow: shadow))
            let size = str.size()
            str.draw(at: CGPoint(x: a.start.x, y: a.start.y - size.height / 2))

        case .counter:
            let d = counterDiameter(for: a.width)
            let r = CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * shadowScale), blur: 3 * shadowScale,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
            NSBezierPath(ovalIn: r).fill()
            ctx.restoreGState()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
            let str = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: d * 0.5, weight: .bold),
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ])
            let s = str.size()
            str.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }

    static func textAttributes(color: NSColor, width: CGFloat, shadow: NSShadow? = nil) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize(for: width), weight: .bold),
            .foregroundColor: color,
        ]
        if let shadow { attrs[.shadow] = shadow }
        return attrs
    }

    static func drawArrow(from s: CGPoint, to e: CGPoint, width w: CGFloat, style: ArrowStyle) {
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let px = -uy, py = ux
        let headLen = min(len * (style == .double ? 0.45 : 0.9), max(16, w * 4.5))
        let headHalf = headLen * 0.5

        func head(at tip: CGPoint, dirX: CGFloat, dirY: CGFloat) -> NSBezierPath {
            let back = CGPoint(x: tip.x - dirX * headLen, y: tip.y - dirY * headLen)
            let p = NSBezierPath()
            p.move(to: CGPoint(x: back.x + px * headHalf, y: back.y + py * headHalf))
            p.line(to: tip)
            p.line(to: CGPoint(x: back.x - px * headHalf, y: back.y - py * headHalf))
            return p
        }

        switch style {
        case .tapered:
            let base = CGPoint(x: e.x - ux * headLen * 0.85, y: e.y - uy * headLen * 0.85)
            let tail = w * 0.25, neck = w * 0.6
            let back = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: s.x + px * tail, y: s.y + py * tail))
            path.line(to: CGPoint(x: base.x + px * neck, y: base.y + py * neck))
            path.line(to: CGPoint(x: back.x + px * headHalf, y: back.y + py * headHalf))
            path.line(to: e)
            path.line(to: CGPoint(x: back.x - px * headHalf, y: back.y - py * headHalf))
            path.line(to: CGPoint(x: base.x - px * neck, y: base.y - py * neck))
            path.line(to: CGPoint(x: s.x - px * tail, y: s.y - py * tail))
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 1
            path.fill()
            path.stroke()

        case .classic, .double:
            let startPt = style == .double ? CGPoint(x: s.x + ux * headLen * 0.8, y: s.y + uy * headLen * 0.8) : s
            let endPt = CGPoint(x: e.x - ux * headLen * 0.8, y: e.y - uy * headLen * 0.8)
            let shaft = NSBezierPath()
            shaft.move(to: startPt)
            shaft.line(to: endPt)
            shaft.lineWidth = w
            shaft.lineCapStyle = .round
            shaft.stroke()
            let h1 = head(at: e, dirX: ux, dirY: uy)
            h1.close()
            h1.fill()
            if style == .double {
                let h2 = head(at: s, dirX: -ux, dirY: -uy)
                h2.close()
                h2.fill()
            }

        case .open:
            let shaft = NSBezierPath()
            shaft.move(to: s)
            shaft.line(to: e)
            shaft.lineWidth = w
            shaft.lineCapStyle = .round
            shaft.stroke()
            let h = head(at: e, dirX: ux, dirY: uy)
            h.lineWidth = w
            h.lineCapStyle = .round
            h.lineJoinStyle = .round
            h.stroke()
        }
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) > 0.7
    }
}

// MARK: - Resizable rect helper (crop, recording area)

enum RectHandle: CaseIterable {
    case move, n, s, e, w, ne, nw, se, sw

    static func hit(_ p: CGPoint, rect r: CGRect, tolerance t: CGFloat) -> RectHandle? {
        let near = { (a: CGFloat, b: CGFloat) in abs(a - b) <= t }
        let inX = p.x >= r.minX - t && p.x <= r.maxX + t, inY = p.y >= r.minY - t && p.y <= r.maxY + t
        guard inX && inY else { return nil }
        let l = near(p.x, r.minX), rr = near(p.x, r.maxX), b = near(p.y, r.minY), top = near(p.y, r.maxY)
        switch (l, rr, b, top) {
        case (true, _, _, true): return .nw
        case (_, true, _, true): return .ne
        case (true, _, true, _): return .sw
        case (_, true, true, _): return .se
        case (true, _, _, _): return .w
        case (_, true, _, _): return .e
        case (_, _, _, true): return .n
        case (_, _, true, _): return .s
        default: return r.contains(p) ? .move : nil
        }
    }

    func apply(to r: CGRect, dx: CGFloat, dy: CGFloat, within bounds: CGRect, minSize: CGFloat = 10) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch self {
        case .move:
            let nx = max(bounds.minX, min(r.minX + dx, bounds.maxX - r.width))
            let ny = max(bounds.minY, min(r.minY + dy, bounds.maxY - r.height))
            return CGRect(x: nx, y: ny, width: r.width, height: r.height)
        case .n: maxY += dy
        case .s: minY += dy
        case .e: maxX += dx
        case .w: minX += dx
        case .ne: maxY += dy; maxX += dx
        case .nw: maxY += dy; minX += dx
        case .se: minY += dy; maxX += dx
        case .sw: minY += dy; minX += dx
        }
        minX = max(bounds.minX, min(minX, maxX - minSize))
        maxX = min(bounds.maxX, max(maxX, minX + minSize))
        minY = max(bounds.minY, min(minY, maxY - minSize))
        maxY = min(bounds.maxY, max(maxY, minY + minSize))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var cursor: NSCursor {
        switch self {
        case .move: .openHand
        case .n, .s: .resizeUpDown
        case .e, .w: .resizeLeftRight
        default: .crosshair
        }
    }

    static func drawHandles(_ r: CGRect, size: CGFloat) {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY),
                   CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                   CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        for p in pts {
            let h = NSBezierPath(ovalIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
            NSColor.white.setFill()
            h.fill()
            NSColor.black.withAlphaComponent(0.4).setStroke()
            h.lineWidth = size / 8
            h.stroke()
        }
    }
}
