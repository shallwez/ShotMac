import AppKit

enum AnnotationTool: Int {
    case text
    case rectangle
    case oval
    case arrow
    case pen

    var usesLineWidthControls: Bool {
        self == .rectangle || self == .oval || self == .arrow || self == .pen
    }
}

enum Annotation {
    case text(String, CGPoint, CGFloat, NSColor)
    case rectangle(CGRect, NSColor, CGFloat)
    case oval(CGRect, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case pen([CGPoint], NSColor, CGFloat)

    func draw() {
        switch self {
        case let .text(text, point, size, color):
            text.draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color
            ])
        case let .rectangle(rect, color, lineWidth):
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = lineWidth
            path.stroke()
        case let .oval(rect, color, lineWidth):
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            path.stroke()
        case let .arrow(start, end, color, lineWidth):
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()

            let angle = atan2(end.y - start.y, end.x - start.x)
            let length: CGFloat = 16
            let head = NSBezierPath()
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle - .pi / 6),
                                  y: end.y - length * sin(angle - .pi / 6)))
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle + .pi / 6),
                                  y: end.y - length * sin(angle + .pi / 6)))
            head.lineWidth = lineWidth
            head.lineCapStyle = .round
            head.stroke()
        case let .pen(points, color, lineWidth):
            color.setStroke()
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}

let defaultTextSize: CGFloat = 18
let defaultAnnotationLineWidth: CGFloat = 2

final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        configureForEditing()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureForEditing()
    }

    private func configureForEditing() {
        isEditable = true
        isSelectable = true
        isScrollable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
    }

    private func centeredRect(for rect: NSRect) -> NSRect {
        var centered = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        centered.origin.y = rect.origin.y + max(0, (rect.height - textHeight) / 2)
        centered.size.height = min(textHeight, rect.height)
        return centered
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(for: rect)
    }

    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: centeredRect(for: rect),
                   in: controlView,
                   editor: textObj,
                   delegate: delegate,
                   event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: centeredRect(for: rect),
                     in: controlView,
                     editor: textObj,
                     delegate: delegate,
                     start: selStart,
                     length: selLength)
    }
}
