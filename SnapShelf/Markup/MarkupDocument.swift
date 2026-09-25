import CoreGraphics
import Foundation

/// The markup tools, in toolbar order.
nonisolated enum MarkupTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, highlighter, text, blur, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .blur: "Pixelate"
        case .crop: "Crop"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .blur: "mosaic"
        case .crop: "crop"
        }
    }

    /// Whether the color and size controls affect this tool.
    var usesStyle: Bool {
        switch self {
        case .arrow, .rectangle, .highlighter, .text: true
        case .blur, .crop: false
        }
    }
}

nonisolated enum MarkupColor: String, CaseIterable, Identifiable {
    case red, yellow, green, blue, black, white

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
        case .yellow: CGColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1)
        case .green: CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: CGColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    /// Outline drawn around text so it stays readable on any background.
    var textOutline: CGColor {
        self == .white ? MarkupColor.black.cgColor : MarkupColor.white.cgColor
    }
}

nonisolated enum MarkupSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var multiplier: CGFloat {
        switch self {
        case .small: 0.6
        case .medium: 1
        case .large: 1.6
        }
    }
}

/// One mark on the screenshot. Every coordinate is in image pixels with a top-left origin, so
/// the same annotation renders identically on screen (scaled down) and in the exported PNG.
nonisolated struct MarkupAnnotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case highlight([CGPoint])
        case text(String, at: CGPoint)
        case blur(CGRect)
    }

    var id = UUID()
    var kind: Kind
    var color: MarkupColor
    var size: MarkupSize
}

/// Everything the user has changed: the marks, in drawing order, plus an optional crop.
nonisolated struct MarkupDocument: Equatable {
    var annotations: [MarkupAnnotation] = []
    /// In image pixels. `nil` exports the whole screenshot.
    var cropRect: CGRect?

    var isEmpty: Bool { annotations.isEmpty && cropRect == nil }
}

/// Snapshot-based undo/redo: every committed edit pushes the previous document.
nonisolated struct MarkupHistory {
    private(set) var document = MarkupDocument()
    private var undoStack: [MarkupDocument] = []
    private var redoStack: [MarkupDocument] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func commit(_ change: (inout MarkupDocument) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }
        undoStack.append(document)
        redoStack.removeAll()
        document = next
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
    }
}

/// Pure geometry shared by the editor and the renderer.
nonisolated enum MarkupGeometry {
    /// The normalised rectangle spanning two points.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Stroke width, in image pixels, for a given size. Scales with the image so marks look the
    /// same weight on a Retina full-screen capture as on a small window capture.
    static func lineWidth(for size: MarkupSize, imageSize: CGSize) -> CGFloat {
        max(2, max(imageSize.width, imageSize.height) / 400) * size.multiplier
    }

    static func fontSize(for size: MarkupSize, imageSize: CGSize) -> CGFloat {
        max(14, max(imageSize.width, imageSize.height) / 400 * 7) * size.multiplier
    }

    /// The three corners of an arrowhead pointing at `to`: tip, then the two back corners.
    static func arrowHead(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> [CGPoint] {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length = hypot(to.x - from.x, to.y - from.y)
        // Never longer than half the arrow, so short arrows still show a shaft.
        let headLength = min(max(lineWidth * 4, 10), length / 2)
        let spread = CGFloat.pi / 7
        return [
            to,
            CGPoint(x: to.x - headLength * cos(angle - spread), y: to.y - headLength * sin(angle - spread)),
            CGPoint(x: to.x - headLength * cos(angle + spread), y: to.y - headLength * sin(angle + spread)),
        ]
    }

    /// Where an image of `imageSize` sits when aspect-fitted into `container`, centered.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Converts a point in the displayed image's frame to image pixels, clamped to the image.
    static func imagePoint(fromView point: CGPoint, displayRect: CGRect, imageSize: CGSize) -> CGPoint {
        guard displayRect.width > 0, displayRect.height > 0 else { return .zero }
        let x = (point.x - displayRect.minX) / displayRect.width * imageSize.width
        let y = (point.y - displayRect.minY) / displayRect.height * imageSize.height
        return CGPoint(x: min(max(x, 0), imageSize.width), y: min(max(y, 0), imageSize.height))
    }

    /// `rect` clamped to the image and rounded out to whole pixels; `nil` if nothing is left.
    static func pixelAlignedCrop(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
        let clamped = rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }
}
