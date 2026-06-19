import AppKit
import Carbon
import CoreGraphics
import ScreenCaptureKit
import ServiceManagement

private let hotKeySignature = OSType(0x514d5348) // QMSH
private let hotKeyID = UInt32(1)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var captureWindow: CaptureWindow?
    private var editorWindow: NSWindow?
    private var editorToolbarWindow: NSWindow?
    private var hotKeyRegistrationStatus: OSStatus = noErr

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("QuickMarkShot runs as a menu bar utility")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LastLaunch")
        NSLog("QuickMarkShot did finish launching")
        buildStatusMenu()
        registerHotKey()
        if Bundle.main.bundleURL.pathExtension == "app" {
            configureLaunchAtLogin()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @objc func startCapture() {
        let hasScreenAccess = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if !hasScreenAccess {
            showScreenRecordingPermissionAlert()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        captureWindow?.orderOut(nil)
        captureWindow = CaptureWindow { [weak self] rect, annotations in
            guard let rect, let annotations else { return }
            self?.capture(rect: rect, annotations: annotations)
        }
        captureWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let shouldEnable = sender.state != .on
        UserDefaults.standard.set(shouldEnable, forKey: "LaunchAtLogin")
        updateLaunchAtLogin(enabled: shouldEnable, reportErrors: true)
    }

    private func buildStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "截图"
        item.button?.font = .systemFont(ofSize: 13, weight: .semibold)
        item.button?.toolTip = "QuickMarkShot 截图（Option+A）"

        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "截图 Option+A", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "开机启动", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        launchAtLoginItem = loginItem
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "StatusMenuBuiltAt")
        NSLog("QuickMarkShot status menu built")
    }

    private func configureLaunchAtLogin() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "LaunchAtLogin") == nil {
            defaults.set(true, forKey: "LaunchAtLogin")
        }
        updateLaunchAtLogin(enabled: defaults.bool(forKey: "LaunchAtLogin"), reportErrors: false)
    }

    private func updateLaunchAtLogin(enabled: Bool, reportErrors: Bool) {
        launchAtLoginItem?.state = enabled ? .on : .off
        Task { @MainActor in
            do {
                if enabled {
                    if SMAppService.mainApp.status == .notRegistered {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status != .notRegistered {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                UserDefaults.standard.set(!enabled, forKey: "LaunchAtLogin")
                launchAtLoginItem?.state = enabled ? .off : .on
                NSLog("QuickMarkShot launch-at-login error: %@", error.localizedDescription)
                if reportErrors {
                    showAlert(title: "开机启动设置失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard event != nil, let userData else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "LastHotKeyEvent")
                Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue().startCapture()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)

        let id = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        hotKeyRegistrationStatus = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        UserDefaults.standard.set(Int(hotKeyRegistrationStatus), forKey: "HotKeyStatus")
        UserDefaults.standard.set(Int(handlerStatus), forKey: "HotKeyHandlerStatus")
        NSLog("QuickMarkShot hotkey handler=%d registration=%d", handlerStatus, hotKeyRegistrationStatus)
    }

    private func capture(rect: CGRect, annotations: [Annotation]) {
        let imageRect = rect.standardized.integral
        guard imageRect.width > 2, imageRect.height > 2 else { return }
        Task { @MainActor in
            do {
                let image = try await captureImage(in: imageRect)
                Clipboard.write(image: render(image: image, annotations: annotations))
            } catch {
                showAlert(title: "截图失败", message: "没有拿到屏幕图像，请确认屏幕录制权限已经开启。\n\(error.localizedDescription)")
            }
        }
    }

    private func render(image: NSImage, annotations: [Annotation]) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        annotations.forEach(drawAnnotation)
        result.unlockFocus()
        return result
    }

    private func drawAnnotation(_ annotation: Annotation) {
        switch annotation {
        case let .text(text, point, size, color):
            text.draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color
            ])
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

    private func captureImage(in selection: CGRect) async throws -> NSImage {
        let midpoint = CGPoint(x: selection.midX, y: selection.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw CaptureError.displayNotFound
        }

        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = available.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let clipped = selection.intersection(screen.frame)
        guard !clipped.isNull else { throw CaptureError.emptySelection }
        let sourceRect = CGRect(
            x: clipped.minX - screen.frame.minX,
            y: screen.frame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(clipped.width * screen.backingScaleFactor)
        configuration.height = Int(clipped.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: cgImage, size: clipped.size)
    }

    private func showEditor(image: NSImage, selection: CGRect, initialTool: AnnotationTool) {
        closeEditor()

        let controller = EditorViewController(image: image, initialTool: initialTool) { [weak self] in
            self?.closeEditor()
        }
        let contentSize = image.size
        let window = EditorWindow(contentRect: CGRect(origin: selection.origin, size: contentSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.level = .screenSaver
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.setFrame(CGRect(origin: selection.origin, size: contentSize), display: false)

        let toolbarSize = CGSize(width: 444, height: 48)
        let toolbarController = EditorToolbarViewController(canvas: controller.canvas, initialTool: initialTool)
        let toolbarWindow = EditorToolbarWindow(contentRect: CGRect(origin: .zero, size: toolbarSize),
                                                styleMask: [.borderless], backing: .buffered, defer: false)
        toolbarWindow.contentViewController = toolbarController
        toolbarWindow.level = .screenSaver
        toolbarWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbarWindow.hidesOnDeactivate = false
        toolbarWindow.isReleasedWhenClosed = false
        toolbarWindow.isOpaque = false
        toolbarWindow.backgroundColor = .clear
        toolbarWindow.hasShadow = true

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main
        var toolbarOrigin = CGPoint(x: selection.maxX - toolbarSize.width,
                                    y: selection.minY - toolbarSize.height - 6)
        if let visibleFrame = screen?.visibleFrame {
            toolbarOrigin.x = min(max(toolbarOrigin.x, visibleFrame.minX), visibleFrame.maxX - toolbarSize.width)
            if toolbarOrigin.y < visibleFrame.minY {
                toolbarOrigin.y = min(selection.maxY + 6, visibleFrame.maxY - toolbarSize.height)
            }
        }
        toolbarWindow.setFrameOrigin(toolbarOrigin)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(controller.canvas)
        toolbarWindow.orderFrontRegardless()
        editorWindow = window
        editorToolbarWindow = toolbarWindow
    }

    private func closeEditor() {
        editorToolbarWindow?.orderOut(nil)
        editorWindow?.orderOut(nil)
        editorToolbarWindow = nil
        editorWindow = nil
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showScreenRecordingPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在系统设置 > 隐私与安全性 > 屏幕录制中允许 QuickMarkShot，然后重新截图。这个权限只需要设置一次。"
        alert.addButton(withTitle: "打开屏幕录制设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class EditorToolbarWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

private enum CaptureError: LocalizedError {
    case displayNotFound
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到对应的显示器。"
        case .emptySelection: return "截图区域为空。"
        }
    }
}

final class CaptureWindow: NSWindow {
    private let completion: (CGRect?, [Annotation]?) -> Void

    init(completion: @escaping (CGRect?, [Annotation]?) -> Void) {
        self.completion = completion
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        contentView = CaptureView(frame: CGRect(origin: .zero, size: frame.size)) { [weak self] rect, annotations in
            self?.orderOut(nil)
            self?.completion(rect, annotations)
        }
    }

    override var canBecomeKey: Bool { true }
}

final class CaptureView: NSView, NSTextFieldDelegate {
    private typealias ActionButtons = (tools: [(tool: AnnotationTool, rect: CGRect)], undo: CGRect, fontSize: CGRect?, colors: [(color: NSColor, rect: CGRect)], copy: CGRect, cancel: CGRect, bar: CGRect)

    private enum ResizeHandle {
        case left, right, bottom, top
        case bottomLeft, bottomRight, topLeft, topRight

        var changesLeft: Bool { self == .left || self == .bottomLeft || self == .topLeft }
        var changesRight: Bool { self == .right || self == .bottomRight || self == .topRight }
        var changesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
        var changesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    }

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var lockedSelection: CGRect?
    private var moveOffset: CGPoint?
    private var resizeHandle: ResizeHandle?
    private var activeTool: AnnotationTool?
    private var annotations: [Annotation] = []
    private var annotationStart: CGPoint?
    private var annotationCurrent: CGPoint?
    private var penPoints: [CGPoint] = []
    private var activeTextField: NSTextField?
    private var activeTextPoint: CGPoint?
    private var textSize: CGFloat = 28
    private var textColor: NSColor = .systemRed
    private let textSizeOptions: [CGFloat] = Array(stride(from: CGFloat(12), through: CGFloat(64), by: CGFloat(2)))
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private let completion: (CGRect?, [Annotation]?) -> Void

    init(frame: CGRect, completion: @escaping (CGRect?, [Annotation]?) -> Void) {
        self.completion = completion
        super.init(frame: frame)
        wantsLayer = true
        window?.acceptsMouseMovedEvents = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoLastAnnotation()
        } else if event.keyCode == kVK_Escape {
            completion(nil, nil)
        } else if event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter {
            copySelection()
        } else if lockedSelection != nil, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "t": selectTool(.text)
            case "r": selectTool(.rectangle)
            case "a": selectTool(.arrow)
            case "p": selectTool(.pen)
            case "-", "–":
                if isTextControlsVisible { adjustTextSize(by: -2) } else { super.keyDown(with: event) }
            case "+", "=":
                if isTextControlsVisible { adjustTextSize(by: 2) } else { super.keyDown(with: event) }
            default: super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        if let field = activeTextField, !field.frame.contains(point) {
            if let lockedSelection {
                let buttons = actionButtonRects(for: lockedSelection)
                if !isPointInToolbar(point, buttons: buttons), !lockedSelection.contains(point) {
                    commitTextEntry()
                    completion(nil, nil)
                    return
                }
            }
            commitTextEntry()
            if let lockedSelection, lockedSelection.contains(point), event.clickCount == 2 {
                copySelection()
            }
            return
        }
        if let lockedSelection {
            let buttons = actionButtonRects(for: lockedSelection)
            if let selected = buttons.tools.first(where: { $0.rect.contains(point) }) {
                commitTextEntry()
                selectTool(selected.tool)
                return
            }
            if buttons.undo.contains(point) {
                undoLastAnnotation()
                needsDisplay = true
                return
            }
            if let fontSize = buttons.fontSize, fontSize.contains(point) {
                showTextSizeMenu(from: fontSize)
                return
            }
            if let selectedColor = buttons.colors.first(where: { $0.rect.contains(point) }) {
                textColor = selectedColor.color
                activeTextField?.textColor = selectedColor.color
                activeTextField?.layer?.borderColor = selectedColor.color.withAlphaComponent(0.75).cgColor
                needsDisplay = true
                return
            }
            if buttons.copy.contains(point) {
                copySelection()
                return
            }
            if buttons.cancel.contains(point) {
                completion(nil, nil)
                return
            }
            if lockedSelection.contains(point), event.clickCount == 2 {
                commitTextEntry()
                copySelection()
                return
            }
            if let handle = resizeHandle(at: point, for: lockedSelection) {
                commitTextEntry()
                resizeHandle = handle
                updateCursor(at: point)
                return
            }
            if let activeTool, lockedSelection.contains(point) {
                commitTextEntry()
                let localPoint = CGPoint(x: point.x - lockedSelection.minX, y: point.y - lockedSelection.minY)
                if activeTool == .text {
                    beginTextEntry(at: localPoint, viewPoint: point)
                    return
                }
                annotationStart = localPoint
                annotationCurrent = localPoint
                penPoints = [localPoint]
                return
            }
            if lockedSelection.contains(point) {
                commitTextEntry()
                moveOffset = CGPoint(x: point.x - lockedSelection.minX,
                                     y: point.y - lockedSelection.minY)
                return
            }
            completion(nil, nil)
            return
        }
        startPoint = point
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let activeTool, let lockedSelection, annotationStart != nil {
            let point = event.locationInWindow
            let localPoint = CGPoint(x: min(max(point.x, lockedSelection.minX), lockedSelection.maxX) - lockedSelection.minX,
                                     y: min(max(point.y, lockedSelection.minY), lockedSelection.maxY) - lockedSelection.minY)
            annotationCurrent = localPoint
            if activeTool == .pen { penPoints.append(localPoint) }
            needsDisplay = true
            return
        }
        if let handle = resizeHandle, var rect = lockedSelection {
            let point = event.locationInWindow
            let minimumSize: CGFloat = 24
            if handle.changesLeft {
                let newMinX = min(max(point.x, bounds.minX), rect.maxX - minimumSize)
                rect.size.width = rect.maxX - newMinX
                rect.origin.x = newMinX
            }
            if handle.changesRight {
                rect.size.width = max(min(point.x, bounds.maxX) - rect.minX, minimumSize)
            }
            if handle.changesBottom {
                let newMinY = min(max(point.y, bounds.minY), rect.maxY - minimumSize)
                rect.size.height = rect.maxY - newMinY
                rect.origin.y = newMinY
            }
            if handle.changesTop {
                rect.size.height = max(min(point.y, bounds.maxY) - rect.minY, minimumSize)
            }
            lockedSelection = rect.integral
            needsDisplay = true
            return
        }
        if let offset = moveOffset, var rect = lockedSelection {
            let point = event.locationInWindow
            rect.origin.x = min(max(point.x - offset.x, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(point.y - offset.y, bounds.minY), bounds.maxY - rect.height)
            lockedSelection = rect
            needsDisplay = true
            return
        }
        currentPoint = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let activeTool, let start = annotationStart, let end = annotationCurrent {
            switch activeTool {
            case .text:
                break
            case .rectangle:
                annotations.append(.rectangle(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y)), textColor))
            case .arrow:
                annotations.append(.arrow(start, end, textColor))
            case .pen:
                if penPoints.count > 1 { annotations.append(.pen(penPoints, textColor)) }
            }
            annotationStart = nil
            annotationCurrent = nil
            penPoints = []
            needsDisplay = true
            return
        }
        if resizeHandle != nil {
            resizeHandle = nil
            updateCursor(at: event.locationInWindow)
            needsDisplay = true
            return
        }
        if moveOffset != nil {
            moveOffset = nil
            updateCursor(at: event.locationInWindow)
            needsDisplay = true
            return
        }
        currentPoint = event.locationInWindow
        guard let selection = selectionRect else {
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
            return
        }
        lockedSelection = selection
        annotations = []
        activeTool = nil
        startPoint = nil
        currentPoint = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let rect = activeSelection else { return }
        NSColor.clear.setFill()
        rect.fill(using: .clear)

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.concat()
        annotations.forEach(drawAnnotation)
        drawAnnotationPreview()
        NSGraphicsContext.restoreGraphicsState()

        drawSizeBadge(text: "\(Int(rect.width)) × \(Int(rect.height))", near: rect)

        if lockedSelection != nil {
            drawActionBar(for: rect)
        }
    }

    private var activeSelection: CGRect? {
        lockedSelection ?? selectionRect
    }

    private func drawSizeBadge(text: String, near rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attrs)
        let badge = CGRect(x: rect.minX + 10,
                           y: rect.maxY + 10,
                           width: textSize.width + 18,
                           height: textSize.height + 9)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let outline = NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8)
        outline.lineWidth = 1
        outline.stroke()
        text.draw(at: CGPoint(x: badge.minX + 9, y: badge.minY + 4), withAttributes: attrs)
    }

    private func resizeHandle(at point: CGPoint, for rect: CGRect) -> ResizeHandle? {
        let hitWidth: CGFloat = 8
        let outer = rect.insetBy(dx: -hitWidth, dy: -hitWidth)
        let inner = rect.insetBy(dx: hitWidth, dy: hitWidth)
        guard outer.contains(point), !inner.contains(point) else { return nil }

        let nearLeft = abs(point.x - rect.minX) <= hitWidth
        let nearRight = abs(point.x - rect.maxX) <= hitWidth
        let nearBottom = abs(point.y - rect.minY) <= hitWidth
        let nearTop = abs(point.y - rect.maxY) <= hitWidth

        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _): return .bottomLeft
        case (true, _, _, true): return .topLeft
        case (_, true, true, _): return .bottomRight
        case (_, true, _, true): return .topRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .bottom
        case (_, _, _, true): return .top
        default: return nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = event.locationInWindow
        hoverPoint = point
        updateCursor(at: point)
        if lockedSelection != nil {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    private func updateCursor(at point: CGPoint) {
        guard let selection = lockedSelection else {
            NSCursor.crosshair.set()
            return
        }
        let buttons = actionButtonRects(for: selection)
        if isPointInToolbar(point, buttons: buttons) {
            NSCursor.pointingHand.set()
        } else if let handle = resizeHandle(at: point, for: selection) {
            cursor(for: handle).set()
        } else if selection.contains(point) {
            if moveOffset != nil {
                NSCursor.closedHand.set()
            } else if activeTool == .text {
                NSCursor.iBeam.set()
            } else if activeTool != nil {
                NSCursor.crosshair.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .bottomLeft, .topRight:
            return .resizeLeftRight
        case .bottomRight, .topLeft:
            return .resizeUpDown
        }
    }

    private func copySelection() {
        commitTextEntry()
        guard let selection = lockedSelection, let window else { return }
        let origin = window.convertPoint(toScreen: selection.origin)
        let maxPoint = window.convertPoint(toScreen: CGPoint(x: selection.maxX, y: selection.maxY))
        completion(CGRect(x: origin.x, y: origin.y,
                          width: maxPoint.x - origin.x,
                          height: maxPoint.y - origin.y).standardized, annotations)
    }

    private func actionButtonRects(for selection: CGRect) -> ActionButtons {
        let showFontSize = isTextControlsVisible
        let barSize = CGSize(width: showFontSize ? 614 : 538, height: 50)
        let x = min(max(selection.maxX - barSize.width, bounds.minX + 4), bounds.maxX - barSize.width - 4)
        let y = selection.minY >= barSize.height + 8
            ? selection.minY - barSize.height - 10
            : min(selection.maxY + 10, bounds.maxY - barSize.height - 4)
        let bar = CGRect(origin: CGPoint(x: x, y: y), size: barSize)
        let colors = colorPalette().enumerated().map { index, color in
            (color: color, rect: CGRect(x: bar.minX + 12 + CGFloat(index) * 28,
                                        y: bar.minY + 14, width: 22, height: 22))
        }
        let fontSize = showFontSize ? CGRect(x: bar.minX + 166, y: bar.minY + 7, width: 64, height: 36) : nil
        let undoX = showFontSize ? bar.minX + 242 : bar.minX + 166
        let undo = CGRect(x: undoX, y: bar.minY + 7, width: 36, height: 36)
        let cancel = CGRect(x: undo.maxX + 8, y: bar.minY + 7, width: 36, height: 36)
        let toolsStartX = cancel.maxX + 18
        let toolValues: [AnnotationTool] = [.text, .rectangle, .arrow, .pen]
        let tools = toolValues.enumerated().map { index, tool in
            (tool: tool, rect: CGRect(x: toolsStartX + CGFloat(index) * 42,
                                     y: bar.minY + 7, width: 36, height: 36))
        }
        return (
            tools: tools,
            undo: undo,
            fontSize: fontSize,
            colors: colors,
            copy: CGRect(x: bar.maxX - 94, y: bar.minY + 7, width: 84, height: 36),
            cancel: cancel,
            bar: bar
        )
    }

    private func isPointInToolbar(_ point: CGPoint, buttons: ActionButtons) -> Bool {
        buttons.bar.contains(point)
            || buttons.tools.contains(where: { $0.rect.contains(point) })
            || buttons.undo.contains(point)
            || (buttons.fontSize?.contains(point) ?? false)
            || buttons.colors.contains(where: { $0.rect.contains(point) })
            || buttons.copy.contains(point)
            || buttons.cancel.contains(point)
    }

    private func drawActionBar(for selection: CGRect) {
        let buttons = actionButtonRects(for: selection)
        drawToolbarBackground(buttons.bar)

        for item in buttons.tools {
            let isActive = item.tool == activeTool
            drawToolbarButton(item.rect, active: isActive, hovered: isHovered(item.rect))
            drawToolbarIcon(symbolName(for: item.tool), fallback: fallbackIcon(for: item.tool), in: item.rect)
        }
        drawToolbarSeparator(x: buttons.undo.minX - 12, bar: buttons.bar)
        drawToolbarButton(buttons.undo, active: false, hovered: isHovered(buttons.undo), enabled: !annotations.isEmpty)
        drawToolbarIcon("arrow.uturn.backward", fallback: "↶", in: buttons.undo, enabled: !annotations.isEmpty)
        drawToolbarButton(buttons.cancel, active: false, hovered: isHovered(buttons.cancel))
        drawToolbarIcon("xmark", fallback: "×", in: buttons.cancel)
        if let firstTool = buttons.tools.first {
            drawToolbarSeparator(x: firstTool.rect.minX - 10, bar: buttons.bar)
        }
        if let fontSize = buttons.fontSize {
            drawToolbarSeparator(x: fontSize.minX - 12, bar: buttons.bar)
            drawFontSizeButton(rect: fontSize, hovered: isHovered(fontSize))
        }
        if let firstColor = buttons.colors.first {
            drawToolbarSeparator(x: firstColor.rect.minX - 12, bar: buttons.bar)
        }
        for item in buttons.colors {
            item.color.setFill()
            NSBezierPath(ovalIn: item.rect).fill()
            (item.color.isEqual(textColor) ? NSColor.white : NSColor.white.withAlphaComponent(0.45)).setStroke()
            let outline = NSBezierPath(ovalIn: item.rect.insetBy(dx: -2, dy: -2))
            outline.lineWidth = item.color.isEqual(textColor) ? 2.2 : 1
            outline.stroke()
        }
        drawPrimaryButton(buttons.copy, hovered: isHovered(buttons.copy))
        drawToolbarIcon("doc.on.doc", fallback: "⧉", in: CGRect(x: buttons.copy.minX + 9, y: buttons.copy.minY, width: 24, height: buttons.copy.height))
        "复制".draw(at: CGPoint(x: buttons.copy.minX + 36, y: buttons.copy.minY + 10), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white
        ])
    }

    private func isHovered(_ rect: CGRect) -> Bool {
        hoverPoint.map { rect.contains($0) } ?? false
    }

    private func drawToolbarBackground(_ rect: CGRect) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        NSColor(calibratedWhite: 0.08, alpha: 0.88).setFill()
        background.fill()

        let gloss = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.13),
            NSColor.white.withAlphaComponent(0.03)
        ])?.draw(in: gloss, angle: 90)

        NSColor.white.withAlphaComponent(0.14).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        outline.lineWidth = 1
        outline.stroke()
    }

    private func drawToolbarButton(_ rect: CGRect, active: Bool, hovered: Bool = false, enabled: Bool = true) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        if active {
            NSGradient(colors: [
                NSColor.systemBlue.withAlphaComponent(0.96),
                NSColor(calibratedRed: 0.02, green: 0.44, blue: 0.98, alpha: 0.96)
            ])?.draw(in: path, angle: 90)
        } else {
            let alpha: CGFloat = enabled ? (hovered ? 0.18 : 0.10) : 0.045
            NSColor.white.withAlphaComponent(alpha).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(hovered && enabled ? 0.20 : 0.08).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawPrimaryButton(_ rect: CGRect, hovered: Bool = false) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        NSGradient(colors: [
            NSColor(calibratedRed: hovered ? 0.12 : 0.05, green: hovered ? 0.68 : 0.62, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.00, green: hovered ? 0.52 : 0.45, blue: 0.98, alpha: 1)
        ])?.draw(in: path, angle: 90)
    }

    private func drawToolbarSeparator(x: CGFloat, bar: CGRect) {
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: x, y: bar.minY + 12))
        path.line(to: CGPoint(x: x, y: bar.maxY - 12))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawFontSizeButton(rect: CGRect, hovered: Bool = false) {
        drawToolbarButton(rect, active: false, hovered: hovered)
        let title = "\(Int(textSize))⌄"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = title.size(withAttributes: attrs)
        title.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.minY + 9), withAttributes: attrs)
    }

    private func colorPalette() -> [NSColor] {
        [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
    }

    private func selectTool(_ tool: AnnotationTool) {
        commitTextEntry()
        activeTool = activeTool == tool ? nil : tool
        needsDisplay = true
    }

    private var isTextControlsVisible: Bool {
        activeTool == .text || activeTextField != nil
    }

    private func undoLastAnnotation() {
        commitTextEntry()
        if !annotations.isEmpty {
            annotations.removeLast()
            needsDisplay = true
        }
    }

    private func adjustTextSize(by delta: CGFloat) {
        textSize = min(max(textSize + delta, 12), 72)
        activeTextField?.font = .systemFont(ofSize: textSize, weight: .semibold)
        if let field = activeTextField {
            var frame = field.frame
            frame.size.height = textSize + 14
            field.frame = frame
        }
        needsDisplay = true
    }

    private func showTextSizeMenu(from rect: CGRect) {
        let menu = NSMenu()
        for size in textSizeOptions {
            let item = NSMenuItem(title: "\(Int(size))", action: #selector(selectTextSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = Int(size) == Int(textSize) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.minY - 4), in: self)
    }

    @objc private func selectTextSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        setTextSize(size)
    }

    private func setTextSize(_ size: CGFloat) {
        textSize = min(max(size, 12), 72)
        activeTextField?.font = .systemFont(ofSize: textSize, weight: .semibold)
        if let field = activeTextField {
            var frame = field.frame
            frame.size.height = textSize + 14
            field.frame = frame
        }
        needsDisplay = true
    }

    private func symbolName(for tool: AnnotationTool) -> String {
        switch tool {
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        }
    }

    private func fallbackIcon(for tool: AnnotationTool) -> String {
        switch tool {
        case .text: return "T"
        case .rectangle: return "▭"
        case .arrow: return "↗"
        case .pen: return "✎"
        }
    }

    private func drawToolbarIcon(_ symbolName: String, fallback: String, in rect: CGRect, enabled: Bool = true) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fallback == "T" ? 17 : 20, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(enabled ? 1 : 0.35)
        ]
        let textSize = fallback.size(withAttributes: attrs)
        fallback.draw(at: CGPoint(x: rect.midX - textSize.width / 2,
                                  y: rect.midY - textSize.height / 2),
                      withAttributes: attrs)
    }

    private func beginTextEntry(at point: CGPoint, viewPoint: CGPoint) {
        commitTextEntry()
        let field = NSTextField(frame: CGRect(x: viewPoint.x, y: viewPoint.y - 3, width: 280, height: textSize + 14))
        field.font = .systemFont(ofSize: textSize, weight: .semibold)
        field.textColor = textColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.16)
        field.isBezeled = false
        field.drawsBackground = true
        field.wantsLayer = true
        field.layer?.borderColor = textColor.withAlphaComponent(0.75).cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 5
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

    @objc private func confirmTextEntry() {
        commitTextEntry()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEntry()
    }

    private func commitTextEntry() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = activeTextPoint
        activeTextField = nil
        activeTextPoint = nil
        field.removeFromSuperview()
        if !text.isEmpty, let point {
            annotations.append(.text(text, point, textSize, textColor))
            needsDisplay = true
        }
    }

    private func drawAnnotationPreview() {
        guard let activeTool, let start = annotationStart, let end = annotationCurrent else { return }
        switch activeTool {
        case .text: break
        case .rectangle:
            drawAnnotation(.rectangle(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y)), textColor))
        case .arrow:
            drawAnnotation(.arrow(start, end, textColor))
        case .pen:
            drawAnnotation(.pen(penPoints, textColor))
        }
    }

    private func drawAnnotation(_ annotation: Annotation) {
        let red = NSColor.systemRed
        red.setStroke()
        red.setFill()

        switch annotation {
        case let .text(text, point, size, color):
            text.draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color
            ])
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

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        let rect = CGRect(x: min(startPoint.x, currentPoint.x),
                          y: min(startPoint.y, currentPoint.y),
                          width: abs(startPoint.x - currentPoint.x),
                          height: abs(startPoint.y - currentPoint.y))
        return rect.width > 4 && rect.height > 4 ? rect : nil
    }
}

enum Clipboard {
    static func write(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}
