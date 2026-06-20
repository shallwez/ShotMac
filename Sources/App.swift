import AppKit
import Carbon
import CoreGraphics
import Darwin
import ScreenCaptureKit
import UniformTypeIdentifiers

private let hotKeySignature = OSType(0x514d5348) // QMSH
private let hotKeyID = UInt32(1)
private let launchAgentLabel = "local.quickmarkshot.loginitem"

enum CaptureAction {
    case copy
    case save
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var captureWindow: CaptureWindow?
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
        captureWindow?.dismiss()
        captureWindow = CaptureWindow { [weak self] rect, annotations, action in
            guard let rect, let annotations else { return }
            self?.capture(rect: rect, annotations: annotations, action: action)
        }
        captureWindow?.present()
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = ""
        item.button?.image = Self.statusBarIcon()
        item.button?.imagePosition = .imageOnly
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

    private static func statusBarIcon() -> NSImage {
        if let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图") {
            image.isTemplate = true
            return image
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setStroke()
        let rect = NSRect(x: 2.5, y: 3.5, width: 13, height: 11)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.lineWidth = 1.6
        path.stroke()

        let lens = NSBezierPath(ovalIn: NSRect(x: 7, y: 6, width: 4, height: 4))
        lens.lineWidth = 1.4
        lens.stroke()

        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: 13, width: 4, height: 2.2),
                     xRadius: 1,
                     yRadius: 1).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func configureLaunchAtLogin() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "LaunchAtLogin") == nil {
            defaults.set(true, forKey: "LaunchAtLogin")
        }
        updateLaunchAtLogin(enabled: defaults.bool(forKey: "LaunchAtLogin"), reportErrors: false)
    }

    private func updateLaunchAtLogin(enabled: Bool, reportErrors: Bool) {
        do {
            try setLaunchAtLogin(enabled: enabled)
            launchAtLoginItem?.state = enabled ? .on : .off
        } catch {
            UserDefaults.standard.set(!enabled, forKey: "LaunchAtLogin")
            launchAtLoginItem?.state = enabled ? .off : .on
            NSLog("QuickMarkShot launch-at-login error: %@", error.localizedDescription)
            if reportErrors {
                showAlert(title: "开机启动设置失败", message: error.localizedDescription)
            }
        }
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private func setLaunchAtLogin(enabled: Bool) throws {
        let fileManager = FileManager.default
        let agentURL = launchAgentURL
        let launchAgentsURL = agentURL.deletingLastPathComponent()

        if enabled {
            try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": ["/usr/bin/open", Bundle.main.bundleURL.path],
                "RunAtLoad": true
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            reloadLaunchAgent(at: agentURL)
        } else {
            unloadLaunchAgent(at: agentURL)
            if fileManager.fileExists(atPath: agentURL.path) {
                try fileManager.removeItem(at: agentURL)
            }
        }
    }

    private func reloadLaunchAgent(at url: URL) {
        unloadLaunchAgent(at: url)
        _ = runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", url.path])
    }

    private func unloadLaunchAgent(at url: URL) {
        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", url.path])
    }

    @discardableResult
    private func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("QuickMarkShot launchctl error: %@", error.localizedDescription)
            return false
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

    private func capture(rect: CGRect, annotations: [Annotation], action: CaptureAction) {
        let imageRect = rect.standardized.integral
        guard imageRect.width > 2, imageRect.height > 2 else { return }
        Task { @MainActor in
            do {
                let image = try await captureImage(in: imageRect)
                let rendered = render(image: image, annotations: annotations)
                switch action {
                case .copy:
                    Clipboard.write(image: rendered)
                    SoundFeedback.playSuccess()
                case .save:
                    save(image: rendered)
                }
            } catch {
                showAlert(title: "截图失败", message: "没有拿到屏幕图像，请确认屏幕录制权限已经开启。\n\(error.localizedDescription)")
            }
        }
    }

    private func save(image: NSImage) {
        guard let data = image.pngData else {
            showAlert(title: "保存失败", message: "无法生成 PNG 图片。")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "QuickMarkShot-\(Self.fileTimestamp()).png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                SoundFeedback.playSuccess()
            } catch {
                self?.showAlert(title: "保存失败", message: error.localizedDescription)
            }
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func render(image: NSImage, annotations: [Annotation]) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        annotations.forEach { $0.draw() }
        result.unlockFocus()
        return result
    }

    private func captureImage(in selection: CGRect) async throws -> NSImage {
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var captures: [(image: NSImage, rect: CGRect)] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = available.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }

            let clipped = selection.intersection(screen.frame).integral
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            let image = try await captureImage(on: screen, display: display, rect: clipped)
            captures.append((image, clipped))
        }

        guard !captures.isEmpty else { throw CaptureError.emptySelection }
        if captures.count == 1, let capture = captures.first, capture.rect.equalTo(selection) {
            return capture.image
        }

        let result = NSImage(size: selection.size)
        result.lockFocus()
        for capture in captures {
            let destination = CGRect(x: capture.rect.minX - selection.minX,
                                     y: capture.rect.minY - selection.minY,
                                     width: capture.rect.width,
                                     height: capture.rect.height)
            capture.image.draw(in: destination,
                               from: CGRect(origin: .zero, size: capture.image.size),
                               operation: NSCompositingOperation.copy,
                               fraction: 1)
        }
        result.unlockFocus()
        return result
    }

    private func captureImage(on screen: NSScreen, display: SCDisplay, rect: CGRect) async throws -> NSImage {
        let sourceRect = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(rect.width * screen.backingScaleFactor)
        configuration.height = Int(rect.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: cgImage, size: rect.size)
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
    private let completion: (CGRect?, [Annotation]?, CaptureAction) -> Void
    private var overlayWindows: [CaptureOverlayWindow] = []

    init(completion: @escaping (CGRect?, [Annotation]?, CaptureAction) -> Void) {
        self.completion = completion
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        setFrame(frame, display: false)
        contentView = CaptureView(frame: CGRect(origin: .zero, size: frame.size)) { [weak self] rect, annotations, action in
            self?.dismiss()
            self?.completion(rect, annotations, action)
        }
    }

    func present() {
        guard let captureView = contentView as? CaptureView else { return }
        if overlayWindows.isEmpty {
            overlayWindows = NSScreen.screens.map { screen in
                CaptureOverlayWindow(screen: screen, sourceView: captureView, sourceWindow: self)
            }
        }

        let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        for window in overlayWindows where window.screen !== mouseScreen {
            window.orderFront(nil)
        }
        (overlayWindows.first { $0.screen === mouseScreen } ?? overlayWindows.first)?.makeKeyAndOrderFront(nil)
        captureView.onDisplayNeeded = { [weak self] in
            self?.overlayWindows.forEach {
                ($0.contentView as? CaptureOverlayView)?.sourceDidChange()
            }
        }
        captureView.needsDisplay = true
    }

    func dismiss() {
        (contentView as? CaptureView)?.onDisplayNeeded = nil
        overlayWindows.forEach { $0.orderOut(nil) }
        super.orderOut(nil)
    }

    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen, sourceView: CaptureView, sourceWindow: NSWindow) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        contentView = CaptureOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                         sourceView: sourceView,
                                         sourceWindow: sourceWindow)
    }

    override var canBecomeKey: Bool { true }
}

final class CaptureOverlayView: NSView {
    private weak var sourceView: CaptureView?
    private weak var sourceWindow: NSWindow?
    private var previousDamageBounds: CGRect = .null

    init(frame: CGRect, sourceView: CaptureView, sourceWindow: NSWindow) {
        self.sourceView = sourceView
        self.sourceWindow = sourceWindow
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sourceView, let sourceWindow, let window else { return }
        let sourceOrigin = sourceWindow.convertPoint(fromScreen: window.frame.origin)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: -sourceOrigin.x, yBy: -sourceOrigin.y)
        transform.concat()
        sourceView.draw(sourceView.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    func sourceDidChange() {
        guard let sourceView, let sourceWindow, let window else { return }
        let currentDamageBounds = sourceView.renderDamageBounds
        var damageBounds = previousDamageBounds.union(currentDamageBounds)
        previousDamageBounds = currentDamageBounds
        guard !damageBounds.isNull, !damageBounds.isEmpty else { return }

        let sourceOrigin = sourceWindow.convertPoint(fromScreen: window.frame.origin)
        damageBounds = damageBounds.offsetBy(dx: -sourceOrigin.x, dy: -sourceOrigin.y)
        let localDamageBounds = damageBounds.intersection(bounds)
        guard !localDamageBounds.isNull, !localDamageBounds.isEmpty else { return }
        setNeedsDisplay(localDamageBounds)
    }

    override func keyDown(with event: NSEvent) {
        sourceView?.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        forwardMouseEvent(event, type: .leftMouseDown) { $0.mouseDown(with: $1) }
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMouseEvent(event, type: .leftMouseDragged) { $0.mouseDragged(with: $1) }
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event, type: .leftMouseUp) { $0.mouseUp(with: $1) }
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseEvent(event, type: .rightMouseDown) { $0.rightMouseDown(with: $1) }
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMouseEvent(event, type: .mouseMoved) { $0.mouseMoved(with: $1) }
    }

    override func mouseExited(with event: NSEvent) {
        sourceView?.mouseExited(with: event)
    }

    private func forwardMouseEvent(_ event: NSEvent,
                                   type: NSEvent.EventType,
                                   action: (CaptureView, NSEvent) -> Void) {
        guard let sourceView, let sourceWindow, let window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let sourcePoint = sourceWindow.convertPoint(fromScreen: screenPoint)
        guard let forwarded = NSEvent.mouseEvent(with: type,
                                                 location: sourcePoint,
                                                 modifierFlags: event.modifierFlags,
                                                 timestamp: event.timestamp,
                                                 windowNumber: sourceWindow.windowNumber,
                                                 context: nil,
                                                 eventNumber: event.eventNumber,
                                                 clickCount: event.clickCount,
                                                 pressure: event.pressure) else { return }
        action(sourceView, forwarded)
    }
}

final class CaptureView: NSView, NSTextFieldDelegate {
    private typealias ActionButtons = (tools: [(tool: AnnotationTool, rect: CGRect)], undo: CGRect, fontSize: CGRect?, strokeWidths: [(width: CGFloat, rect: CGRect)], colors: [(color: NSColor, rect: CGRect)], save: CGRect, cancel: CGRect, bar: CGRect)

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
    private var pendingTextIndex: Int?
    private var pendingTextOffset: CGPoint?
    private var pendingTextMouseDownPoint: CGPoint?
    private var draggingTextIndex: Int?
    private var draggingTextOffset: CGPoint?
    private var activeTextField: NSTextField?
    private var activeTextPoint: CGPoint?
    private var activeTextEditingIndex: Int?
    private var textSize: CGFloat = 18
    private var textColor: NSColor = .systemRed
    private var annotationLineWidth: CGFloat = defaultAnnotationLineWidth
    private let lineWidthOptions: [CGFloat] = [2, 4]
    private let textSizeOptions: [CGFloat] = Array(stride(from: CGFloat(12), through: CGFloat(64), by: CGFloat(2)))
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var globalMouseMonitor: Any?
    private let completion: (CGRect?, [Annotation]?, CaptureAction) -> Void
    var onDisplayNeeded: (() -> Void)?

    init(frame: CGRect, completion: @escaping (CGRect?, [Annotation]?, CaptureAction) -> Void) {
        self.completion = completion
        super.init(frame: frame)
        wantsLayer = true
        window?.acceptsMouseMovedEvents = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        endGlobalMouseTracking()
    }

    override var acceptsFirstResponder: Bool { true }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue {
                onDisplayNeeded?()
            } else {
                super.needsDisplay = false
            }
        }
    }

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
            completion(nil, nil, .copy)
        } else if event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter {
            finishSelection(.copy)
        } else if lockedSelection != nil, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "t": selectTool(.text)
            case "r": selectTool(.rectangle)
            case "o": selectTool(.oval)
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
        beginGlobalMouseTracking()
        if let field = activeTextField, !field.frame.contains(point) {
            if let lockedSelection {
                let buttons = actionButtonRects(for: lockedSelection)
                if !isPointInToolbar(point, buttons: buttons), !lockedSelection.contains(point) {
                    commitTextEntry()
                    completion(nil, nil, .copy)
                    return
                }
            }
            commitTextEntry()
            if let lockedSelection, lockedSelection.contains(point), event.clickCount == 2 {
                finishSelection(.copy)
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
            if let selectedWidth = buttons.strokeWidths.first(where: { $0.rect.contains(point) }) {
                annotationLineWidth = selectedWidth.width
                needsDisplay = true
                return
            }
            if let selectedColor = buttons.colors.first(where: { $0.rect.contains(point) }) {
                textColor = selectedColor.color
                activeTextField?.textColor = selectedColor.color
                activeTextField?.layer?.borderColor = selectedColor.color.withAlphaComponent(0.75).cgColor
                needsDisplay = true
                return
            }
            if buttons.save.contains(point) {
                finishSelection(.save)
                return
            }
            if buttons.cancel.contains(point) {
                completion(nil, nil, .copy)
                return
            }
            if lockedSelection.contains(point), event.clickCount == 2 {
                commitTextEntry()
                finishSelection(.copy)
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
                if prepareTextInteraction(at: localPoint, mousePoint: point) {
                    return
                }
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
                let localPoint = CGPoint(x: point.x - lockedSelection.minX, y: point.y - lockedSelection.minY)
                if prepareTextInteraction(at: localPoint, mousePoint: point) {
                    return
                }
                moveOffset = CGPoint(x: point.x - lockedSelection.minX,
                                     y: point.y - lockedSelection.minY)
                return
            }
            completion(nil, nil, .copy)
            return
        }
        startPoint = point
        currentPoint = startPoint
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard lockedSelection == nil else {
            super.rightMouseDown(with: event)
            return
        }
        startPoint = nil
        currentPoint = nil
        endGlobalMouseTracking()
        completion(nil, nil, .copy)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDragged(at: localMousePoint(fallback: event.locationInWindow))
    }

    private func handleMouseDragged(at point: CGPoint) {
        if let textIndex = pendingTextIndex,
           let offset = pendingTextOffset,
           let mouseDownPoint = pendingTextMouseDownPoint {
            if hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) < 3 {
                return
            }
            draggingTextIndex = textIndex
            draggingTextOffset = offset
            pendingTextIndex = nil
            pendingTextOffset = nil
            pendingTextMouseDownPoint = nil
            moveTextAnnotation(at: textIndex, offset: offset, to: point)
            return
        }
        if let textIndex = draggingTextIndex,
           let offset = draggingTextOffset {
            moveTextAnnotation(at: textIndex, offset: offset, to: point)
            return
        }
        if let activeTool, let lockedSelection, annotationStart != nil {
            let localPoint = CGPoint(x: min(max(point.x, lockedSelection.minX), lockedSelection.maxX) - lockedSelection.minX,
                                     y: min(max(point.y, lockedSelection.minY), lockedSelection.maxY) - lockedSelection.minY)
            annotationCurrent = localPoint
            if activeTool == .pen { penPoints.append(localPoint) }
            needsDisplay = true
            return
        }
        if let handle = resizeHandle, var rect = lockedSelection {
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
            rect.origin.x = min(max(point.x - offset.x, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(point.y - offset.y, bounds.minY), bounds.maxY - rect.height)
            lockedSelection = rect
            needsDisplay = true
            return
        }
        currentPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(at: localMousePoint(fallback: event.locationInWindow))
        endGlobalMouseTracking()
    }

    private func handleMouseUp(at point: CGPoint) {
        if let textIndex = pendingTextIndex {
            pendingTextIndex = nil
            pendingTextOffset = nil
            pendingTextMouseDownPoint = nil
            beginEditingTextAnnotation(at: textIndex)
            return
        }
        if draggingTextIndex != nil {
            draggingTextIndex = nil
            draggingTextOffset = nil
            updateCursor(at: point)
            needsDisplay = true
            return
        }
        if let activeTool, let start = annotationStart, let end = annotationCurrent {
            switch activeTool {
            case .text:
                break
            case .rectangle:
                annotations.append(.rectangle(rect(from: start, to: end), textColor, annotationLineWidth))
            case .oval:
                annotations.append(.oval(rect(from: start, to: end), textColor, annotationLineWidth))
            case .arrow:
                annotations.append(.arrow(start, end, textColor, annotationLineWidth))
            case .pen:
                if penPoints.count > 1 { annotations.append(.pen(penPoints, textColor, annotationLineWidth)) }
            }
            annotationStart = nil
            annotationCurrent = nil
            penPoints = []
            needsDisplay = true
            return
        }
        if resizeHandle != nil {
            resizeHandle = nil
            updateCursor(at: point)
            needsDisplay = true
            return
        }
        if moveOffset != nil {
            moveOffset = nil
            updateCursor(at: point)
            needsDisplay = true
            return
        }
        currentPoint = point
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

    private func beginGlobalMouseTracking() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                let point = self.localMousePoint()
                if event.type == .leftMouseDragged {
                    self.handleMouseDragged(at: point)
                } else {
                    self.handleMouseUp(at: point)
                    self.endGlobalMouseTracking()
                }
            }
        }
    }

    private func endGlobalMouseTracking() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func localMousePoint(fallback: CGPoint? = nil) -> CGPoint {
        guard let window else { return fallback ?? .zero }
        return window.convertPoint(fromScreen: NSEvent.mouseLocation)
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
        for (index, annotation) in annotations.enumerated() where index != activeTextEditingIndex {
            annotation.draw()
        }
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

    var renderDamageBounds: CGRect {
        guard let selection = activeSelection else { return .null }
        var damageBounds = selection.insetBy(dx: -18, dy: -58)
        if lockedSelection != nil {
            damageBounds = damageBounds.union(actionButtonRects(for: selection).bar.insetBy(dx: -4, dy: -4))
        }
        return damageBounds
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
            let localPoint = CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
            if moveOffset != nil || draggingTextIndex != nil {
                NSCursor.closedHand.set()
            } else if textAnnotationIndex(at: localPoint) != nil {
                NSCursor.openHand.set()
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

    private func finishSelection(_ action: CaptureAction) {
        commitTextEntry()
        guard let selection = lockedSelection, let window else { return }
        let origin = window.convertPoint(toScreen: selection.origin)
        let maxPoint = window.convertPoint(toScreen: CGPoint(x: selection.maxX, y: selection.maxY))
        completion(CGRect(x: origin.x, y: origin.y,
                          width: maxPoint.x - origin.x,
                          height: maxPoint.y - origin.y).standardized, annotations, action)
    }

    private func actionButtonRects(for selection: CGRect) -> ActionButtons {
        let showFontSize = isTextControlsVisible
        let showStrokeWidths = activeTool?.usesLineWidthControls == true
        let barSize = CGSize(width: showFontSize ? 632 : (showStrokeWidths ? 668 : 580), height: 50)
        let margin: CGFloat = 8
        let gap: CGFloat = 10
        let visibleBounds = visibleToolbarBounds(for: selection)
        let maxX = max(visibleBounds.minX + margin, visibleBounds.maxX - barSize.width - margin)
        let x = min(max(selection.maxX - barSize.width, visibleBounds.minX + margin), maxX)
        let availableBelow = selection.minY - visibleBounds.minY - gap
        let availableAbove = visibleBounds.maxY - selection.maxY - gap
        let preferredY: CGFloat
        if availableBelow >= barSize.height {
            preferredY = selection.minY - barSize.height - gap
        } else if availableAbove >= barSize.height {
            preferredY = selection.maxY + gap
        } else if availableAbove >= availableBelow {
            preferredY = visibleBounds.maxY - barSize.height - margin
        } else {
            preferredY = visibleBounds.minY + margin
        }
        let maxY = max(visibleBounds.minY + margin, visibleBounds.maxY - barSize.height - margin)
        let y = min(max(preferredY, visibleBounds.minY + margin), maxY)
        let bar = CGRect(origin: CGPoint(x: x, y: y), size: barSize)
        let colors = colorPalette().enumerated().map { index, color in
            (color: color, rect: CGRect(x: bar.minX + 12 + CGFloat(index) * 28,
                                        y: bar.minY + 14, width: 22, height: 22))
        }
        let fontSize = showFontSize ? CGRect(x: bar.minX + 158, y: bar.minY + 7, width: 52, height: 36) : nil
        let strokeWidths = showStrokeWidths ? lineWidthOptions.enumerated().map { index, width in
            (width: width, rect: CGRect(x: bar.minX + 158 + CGFloat(index) * 42,
                                        y: bar.minY + 7, width: 36, height: 36))
        } : []
        let undoX = showFontSize ? bar.minX + 222 : (showStrokeWidths ? bar.minX + 254 : bar.minX + 166)
        let undo = CGRect(x: undoX, y: bar.minY + 7, width: 36, height: 36)
        let cancel = CGRect(x: undo.maxX + 8, y: bar.minY + 7, width: 36, height: 36)
        let toolsStartX = cancel.maxX + 18
        let toolValues: [AnnotationTool] = [.text, .rectangle, .oval, .arrow, .pen]
        let tools = toolValues.enumerated().map { index, tool in
            (tool: tool, rect: CGRect(x: toolsStartX + CGFloat(index) * 42,
                                     y: bar.minY + 7, width: 36, height: 36))
        }
        return (
            tools: tools,
            undo: undo,
            fontSize: fontSize,
            strokeWidths: strokeWidths,
            colors: colors,
            save: CGRect(x: bar.maxX - 94, y: bar.minY + 7, width: 84, height: 36),
            cancel: cancel,
            bar: bar
        )
    }

    private func visibleToolbarBounds(for selection: CGRect) -> CGRect {
        guard let window else { return bounds }
        let selectionMidpoint = CGPoint(x: selection.midX, y: selection.midY)
        let screenPoint = window.convertPoint(toScreen: selectionMidpoint)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main else {
            return bounds
        }

        let visibleOrigin = window.convertPoint(fromScreen: screen.visibleFrame.origin)
        let visibleMaxPoint = window.convertPoint(fromScreen: CGPoint(x: screen.visibleFrame.maxX,
                                                                      y: screen.visibleFrame.maxY))
        let visibleRect = CGRect(x: min(visibleOrigin.x, visibleMaxPoint.x),
                                 y: min(visibleOrigin.y, visibleMaxPoint.y),
                                 width: abs(visibleMaxPoint.x - visibleOrigin.x),
                                 height: abs(visibleMaxPoint.y - visibleOrigin.y))
        let clipped = visibleRect.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? bounds : clipped
    }

    private func isPointInToolbar(_ point: CGPoint, buttons: ActionButtons) -> Bool {
        buttons.bar.contains(point)
            || buttons.tools.contains(where: { $0.rect.contains(point) })
            || buttons.undo.contains(point)
            || (buttons.fontSize?.contains(point) ?? false)
            || buttons.strokeWidths.contains(where: { $0.rect.contains(point) })
            || buttons.colors.contains(where: { $0.rect.contains(point) })
            || buttons.save.contains(point)
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
        if let firstStrokeWidth = buttons.strokeWidths.first {
            drawToolbarSeparator(x: firstStrokeWidth.rect.minX - 12, bar: buttons.bar)
            for item in buttons.strokeWidths {
                drawStrokeWidthButton(rect: item.rect,
                                      width: item.width,
                                      active: item.width == annotationLineWidth,
                                      hovered: isHovered(item.rect))
            }
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
        drawPrimaryButton(buttons.save, hovered: isHovered(buttons.save))
        drawToolbarIcon("square.and.arrow.down", fallback: "↓", in: CGRect(x: buttons.save.minX + 9, y: buttons.save.minY, width: 24, height: buttons.save.height))
        "保存".draw(at: CGPoint(x: buttons.save.minX + 36, y: buttons.save.minY + 10), withAttributes: [
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
        let title = "\(Int(textSize))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = title.size(withAttributes: attrs)
        let contentWidth = size.width + 11
        title.draw(at: CGPoint(x: rect.midX - contentWidth / 2, y: rect.minY + 9), withAttributes: attrs)

        let chevronX = rect.midX + contentWidth / 2 - 7
        let chevronY = rect.midY - 2
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: chevronX, y: chevronY + 3))
        chevron.line(to: CGPoint(x: chevronX + 4, y: chevronY - 1))
        chevron.line(to: CGPoint(x: chevronX + 8, y: chevronY + 3))
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        chevron.stroke()
    }

    private func drawStrokeWidthButton(rect: CGRect, width: CGFloat, active: Bool, hovered: Bool = false) {
        drawToolbarButton(rect, active: active, hovered: hovered)
        let line = NSBezierPath()
        line.move(to: CGPoint(x: rect.minX + 9, y: rect.midY))
        line.line(to: CGPoint(x: rect.maxX - 9, y: rect.midY))
        line.lineWidth = width
        line.lineCapStyle = .round
        (active ? NSColor.white : NSColor.white.withAlphaComponent(0.85)).setStroke()
        line.stroke()
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
        case .oval: return "oval"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        }
    }

    private func fallbackIcon(for tool: AnnotationTool) -> String {
        switch tool {
        case .text: return "T"
        case .rectangle: return "▭"
        case .oval: return "○"
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

    private func beginTextEntry(at point: CGPoint, viewPoint: CGPoint, text: String = "", editingIndex: Int? = nil) {
        commitTextEntry()
        let field = NSTextField(frame: CGRect(x: viewPoint.x, y: viewPoint.y - 3, width: 280, height: textSize + 14))
        field.cell = VerticallyCenteredTextFieldCell(textCell: text)
        field.isEditable = true
        field.isSelectable = true
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
        field.stringValue = text
        field.delegate = self
        field.target = self
        field.action = #selector(confirmTextEntry)
        addSubview(field)
        activeTextField = field
        activeTextPoint = point
        activeTextEditingIndex = editingIndex
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.activeTextField === field else { return }
            self.window?.makeFirstResponder(field)
            field.selectText(nil)
            field.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func confirmTextEntry() {
        commitTextEntry()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Text is committed explicitly by Return, save, or clicking outside the field.
    }

    private func commitTextEntry() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = activeTextPoint
        let editingIndex = activeTextEditingIndex
        activeTextField = nil
        activeTextPoint = nil
        activeTextEditingIndex = nil
        field.removeFromSuperview()
        if let editingIndex, annotations.indices.contains(editingIndex) {
            if text.isEmpty {
                annotations.remove(at: editingIndex)
            } else if let point {
                annotations[editingIndex] = .text(text, point, textSize, textColor)
            }
            needsDisplay = true
        } else if !text.isEmpty, let point {
            annotations.append(.text(text, point, textSize, textColor))
            needsDisplay = true
        }
    }

    private func drawAnnotationPreview() {
        guard let activeTool, let start = annotationStart, let end = annotationCurrent else { return }
        switch activeTool {
        case .text: break
        case .rectangle:
            Annotation.rectangle(rect(from: start, to: end), textColor, annotationLineWidth).draw()
        case .oval:
            Annotation.oval(rect(from: start, to: end), textColor, annotationLineWidth).draw()
        case .arrow:
            Annotation.arrow(start, end, textColor, annotationLineWidth).draw()
        case .pen:
            Annotation.pen(penPoints, textColor, annotationLineWidth).draw()
        }
    }

    private func textAnnotationIndex(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed() {
            guard case let .text(text, textPoint, size, _) = annotations[index] else { continue }
            if textAnnotationBounds(text, point: textPoint, size: size).contains(point) {
                return index
            }
        }
        return nil
    }

    private func prepareTextInteraction(at localPoint: CGPoint, mousePoint: CGPoint) -> Bool {
        guard let textIndex = textAnnotationIndex(at: localPoint),
              case let .text(_, textPoint, _, _) = annotations[textIndex] else { return false }
        pendingTextIndex = textIndex
        pendingTextOffset = CGPoint(x: localPoint.x - textPoint.x, y: localPoint.y - textPoint.y)
        pendingTextMouseDownPoint = mousePoint
        updateCursor(at: mousePoint)
        return true
    }

    private func beginEditingTextAnnotation(at index: Int) {
        guard let lockedSelection,
              annotations.indices.contains(index),
              case let .text(text, point, size, color) = annotations[index] else { return }
        textSize = size
        textColor = color
        let viewPoint = CGPoint(x: lockedSelection.minX + point.x, y: lockedSelection.minY + point.y)
        beginTextEntry(at: point, viewPoint: viewPoint, text: text, editingIndex: index)
        needsDisplay = true
    }

    private func moveTextAnnotation(at index: Int, offset: CGPoint, to point: CGPoint) {
        guard let lockedSelection,
              annotations.indices.contains(index),
              case let .text(text, _, size, color) = annotations[index] else { return }
        let localPoint = CGPoint(x: min(max(point.x, lockedSelection.minX), lockedSelection.maxX) - lockedSelection.minX,
                                 y: min(max(point.y, lockedSelection.minY), lockedSelection.maxY) - lockedSelection.minY)
        let textSize = annotationTextSize(text, size: size)
        let nextPoint = CGPoint(x: min(max(localPoint.x - offset.x, 0), max(0, lockedSelection.width - textSize.width)),
                                y: min(max(localPoint.y - offset.y, 0), max(0, lockedSelection.height - textSize.height)))
        annotations[index] = .text(text, nextPoint, size, color)
        needsDisplay = true
    }

    private func textAnnotationBounds(_ text: String, point: CGPoint, size: CGFloat) -> CGRect {
        let textSize = text.size(withAttributes: textAttributes(size: size))
        return CGRect(origin: point, size: textSize).insetBy(dx: -8, dy: -6)
    }

    private func annotationTextSize(_ text: String, size: CGFloat) -> CGSize {
        text.size(withAttributes: textAttributes(size: size))
    }

    private func textAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        let rect = rect(from: startPoint, to: currentPoint)
        return rect.width > 4 && rect.height > 4 ? rect : nil
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(start.x - end.x),
               height: abs(start.y - end.y))
    }
}

enum Clipboard {
    static func write(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

enum SoundFeedback {
    static func playSuccess() {
        if let sound = NSSound(named: "Pop") ?? NSSound(named: "Tink") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
