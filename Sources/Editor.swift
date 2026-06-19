import AppKit

enum AnnotationTool: Int {
    case text
    case rectangle
    case arrow
    case pen
}

enum Annotation {
    case text(String, CGPoint, CGFloat, NSColor)
    case rectangle(CGRect, NSColor)
    case arrow(CGPoint, CGPoint, NSColor)
    case pen([CGPoint], NSColor)
}

final class EditorViewController: NSViewController {
    let canvas: AnnotationCanvasView

    init(image: NSImage, initialTool: AnnotationTool = .rectangle, onClose: @escaping () -> Void) {
        canvas = AnnotationCanvasView(image: image, onClose: onClose)
        canvas.tool = initialTool
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = canvas
    }
}

final class EditorToolbarViewController: NSViewController {
    private let canvas: AnnotationCanvasView
    private let initialTool: AnnotationTool
    private var toolButtons: [NSButton] = []

    init(canvas: AnnotationCanvasView, initialTool: AnnotationTool) {
        self.canvas = canvas
        self.initialTool = initialTool
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        let toolbarBackground = NSView()
        toolbarBackground.wantsLayer = true
        toolbarBackground.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        toolbarBackground.layer?.cornerRadius = 7
        toolbarBackground.layer?.masksToBounds = true

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)

        let tools: [(String, String, AnnotationTool)] = [
            ("textformat", "文字", .text),
            ("square", "矩形", .rectangle),
            ("arrow.up.right", "箭头", .arrow),
            ("pencil.tip", "画笔", .pen)
        ]
        for (symbol, tooltip, tool) in tools {
            let button = iconButton(symbol: symbol, tooltip: tooltip, action: #selector(selectTool(_:)))
            button.tag = tool.rawValue
            button.setButtonType(.toggle)
            button.state = tool == initialTool ? .on : .off
            toolButtons.append(button)
            toolbar.addArrangedSubview(button)
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolbar.addArrangedSubview(divider)

        toolbar.addArrangedSubview(iconButton(symbol: "arrow.uturn.backward", tooltip: "撤销", action: #selector(undo)))
        toolbar.addArrangedSubview(iconButton(symbol: "doc.on.clipboard", tooltip: "复制并关闭", action: #selector(copyResult)))

        root.addSubview(toolbarBackground)
        toolbarBackground.addSubview(toolbar)
        toolbarBackground.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbarBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarBackground.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: toolbarBackground.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbarBackground.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: toolbarBackground.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: toolbarBackground.bottomAnchor)
        ])

        view = root
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        canvas.tool = tool
        toolButtons.forEach { $0.state = $0 === sender ? .on : .off }
        canvas.window?.makeKeyAndOrderFront(nil)
        canvas.window?.makeFirstResponder(canvas)
    }

    @objc private func undo() {
        canvas.undo()
    }

    @objc private func copyResult() {
        canvas.copyAndClose()
    }

    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(title: tooltip, target: self, action: action)
        button.image = image
        button.toolTip = tooltip
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: tooltip == "复制并关闭" ? 94 : 62).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
}

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    var tool: AnnotationTool = .rectangle
    private let image: NSImage
    private let onClose: () -> Void
    private var annotations: [Annotation] = []
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var penPoints: [CGPoint] = []
    private var activeTextField: NSTextField?
    private var activeTextPoint: CGPoint?

    init(image: NSImage, onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.borderWidth = 2
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1)

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: imageRect.minX, yBy: imageRect.minY)
        transform.scaleX(by: imageRect.width / image.size.width, yBy: imageRect.height / image.size.height)
        transform.concat()
        annotations.forEach(drawAnnotation)
        drawPreview()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelTextEntry()
            onClose()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            commitTextEntry()
            copyAndClose()
            return
        }

        commitTextEntry()
        guard let point = imagePoint(from: viewPoint) else { return }
        window?.makeFirstResponder(self)
        if tool == .text {
            beginTextEntry(at: point, viewPoint: viewPoint)
            return
        }
        dragStart = point
        dragCurrent = point
        penPoints = [point]
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let point = imagePoint(from: viewPoint) else { return }
        dragCurrent = point
        if tool == .pen { penPoints.append(point) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, let end = imagePoint(from: viewPoint) ?? dragCurrent else { return }
        switch tool {
        case .rectangle: annotations.append(.rectangle(rect(from: start, to: end), .systemRed))
        case .arrow: annotations.append(.arrow(start, end, .systemRed))
        case .pen:
            if penPoints.count > 1 { annotations.append(.pen(penPoints, .systemRed)) }
        case .text: break
        }
        dragStart = nil
        dragCurrent = nil
        penPoints = []
        needsDisplay = true
    }

    func undo() {
        cancelTextEntry()
        if !annotations.isEmpty {
            annotations.removeLast()
            needsDisplay = true
        }
    }

    func copyAndClose() {
        commitTextEntry()
        Clipboard.write(image: renderedImage())
        onClose()
    }

    func renderedImage() -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        annotations.forEach(drawAnnotation)
        result.unlockFocus()
        return result
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEntry()
    }

    @objc private func confirmTextEntry() {
        commitTextEntry()
        window?.makeFirstResponder(self)
    }

    private var imageRect: CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func imagePoint(from viewPoint: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.contains(viewPoint) else { return nil }
        return CGPoint(x: (viewPoint.x - rect.minX) * image.size.width / rect.width,
                       y: (viewPoint.y - rect.minY) * image.size.height / rect.height)
    }

    private func beginTextEntry(at point: CGPoint, viewPoint: CGPoint) {
        let field = NSTextField(frame: CGRect(x: viewPoint.x, y: viewPoint.y - 3, width: 240, height: 32))
        field.font = .systemFont(ofSize: 24, weight: .semibold)
        field.textColor = .systemRed
        field.backgroundColor = NSColor.white.withAlphaComponent(0.88)
        field.isBezeled = false
        field.focusRingType = .none
        field.placeholderString = "输入文字，回车确认"
        field.delegate = self
        field.target = self
        field.action = #selector(confirmTextEntry)
        addSubview(field)
        activeTextField = field
        activeTextPoint = point
        window?.makeFirstResponder(field)
    }

    private func commitTextEntry() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = activeTextPoint
        activeTextField = nil
        activeTextPoint = nil
        field.removeFromSuperview()
        if !text.isEmpty, let point {
            annotations.append(.text(text, point, 24, .systemRed))
            needsDisplay = true
        }
    }

    private func cancelTextEntry() {
        activeTextField?.removeFromSuperview()
        activeTextField = nil
        activeTextPoint = nil
    }

    private func drawPreview() {
        guard let start = dragStart, let end = dragCurrent else { return }
        switch tool {
        case .rectangle: drawAnnotation(.rectangle(rect(from: start, to: end), .systemRed))
        case .arrow: drawAnnotation(.arrow(start, end, .systemRed))
        case .pen: drawAnnotation(.pen(penPoints, .systemRed))
        case .text: break
        }
    }

    private func drawAnnotation(_ annotation: Annotation) {
        let red = NSColor.systemRed
        red.setStroke()
        red.setFill()

        switch annotation {
        case let .text(text, point, size, color):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color
            ]
            text.draw(at: point, withAttributes: attrs)

        case let .rectangle(rect, color):
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = 4
            path.stroke()

        case let .arrow(start, end, color):
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.stroke()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length: CGFloat = 16
            let head = NSBezierPath()
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
            head.lineWidth = 4
            head.lineCapStyle = .round
            head.stroke()

        case let .pen(points, color):
            color.setStroke()
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}
