import AppKit
import IOSurface

/// Remote desktop settings that apply to every connection, kept in the
/// user defaults and switched from View ▸ Remote Desktop.
enum RdpPreferences {
    /// Ask for a desktop at the display's full pixel resolution. Off asks
    /// for one pixel per point: a quarter of the pixels, so less to encode,
    /// send and decode.
    static let retinaKey = "rdpRetinaResolution"
    /// Offer the graphics pipeline (H.264) and RemoteFX. Off is the plain
    /// bitmap mode for a host that misbehaves with them.
    static let fastGraphicsKey = "rdpFastGraphics"
    /// Share the clipboard with remote desktops.
    static let clipboardKey = "rdpShareClipboard"

    static let didChange = Notification.Name("RdpPreferencesDidChange")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [retinaKey: true, fastGraphicsKey: true, clipboardKey: true])
    }

    static var retina: Bool { UserDefaults.standard.bool(forKey: retinaKey) }
    static var fastGraphics: Bool { UserDefaults.standard.bool(forKey: fastGraphicsKey) }
    static var shareClipboard: Bool { UserDefaults.standard.bool(forKey: clipboardKey) }

    static func toggle(_ key: String) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// A remote desktop pane. The Rust core decodes the session into an
/// IOSurface that a layer displays; the desktop's size follows this view's
/// size. The Mac's clipboard is shared with the remote desktop while the
/// pane has the keyboard.
final class RdpSessionView: NSView, PaneContent {
    let connection: Connection

    private var session: RdpSession?
    private var bridge: RdpBridge?
    private let surfaceLayer = CALayer()
    /// The surface on screen.
    private var surface: IOSurfaceRef?
    /// The surface of a desktop size that has not been painted yet. The
    /// old one stays on screen, scaled, until it has: no black flash.
    private var incomingSurface: IOSurfaceRef?
    private var frameWidth = 0
    private var frameHeight = 0
    private var username = ""
    private var password = ""
    private var domain: String?
    private var pendingResize: DispatchWorkItem?
    private var lastRequestedSize: (Int, Int) = (0, 0)
    /// The last error the session reported, shown when it then closes.
    private var lastError: String?
    private var usesFastGraphics = false
    private var trackingArea: NSTrackingArea?
    private var modifierFlags: NSEvent.ModifierFlags = []
    private var terminated = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var noticeHide: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    // Clipboard sharing. What is on the Mac's clipboard is announced to the
    // remote desktop only while this pane has the keyboard, and handed over
    // only while the clipboard still holds what was announced.
    private var clipboardReady = false
    /// The pasteboard change count this pane last looked at.
    private var seenChangeCount = -1
    /// The change count of the contents announced to the remote, while they
    /// are the remote's to paste.
    private var offeredChangeCount: Int?
    /// The remote copied text while this pane did not have the keyboard.
    private var remoteTextWaiting = false
    private var pasteboardTimer: Timer?

    // MARK: PaneContent

    var view: NSView { self }
    private(set) var title: String {
        didSet { onTitleChange?(title) }
    }
    private(set) var isLive = false {
        didSet { onStateChange?() }
    }
    var onTitleChange: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onFocus: (() -> Void)?
    var onSessionEnded: ((Bool) -> Void)?

    init(connection: Connection) {
        self.connection = connection
        self.title = connection.name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        surfaceLayer.contentsGravity = .resize
        surfaceLayer.magnificationFilter = .linear
        surfaceLayer.minificationFilter = .linear
        surfaceLayer.isOpaque = true
        layer?.addSublayer(surfaceLayer)

        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 13)
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)

        notice.alignment = .center
        notice.textColor = .white
        notice.font = NSFont.systemFont(ofSize: 12)
        notice.drawsBackground = true
        notice.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        notice.isHidden = true
        notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)

        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
        setStatus("Resolving credentials for \(connection.name)…")

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: RdpPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardFocusChanged() }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSWindow) === self.window else { return }
                    self.keyboardFocusChanged()
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        // After the responder change has taken effect.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.keyboardFocusChanged() }
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.keyboardFocusChanged() }
        }
        return true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = bounds
        CATransaction.commit()
        scheduleResize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        surfaceLayer.contentsScale = window?.backingScaleFactor ?? 2
        scheduleResize()
    }

    /// The drag is over: ask for the final size at once.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        requestResize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Lifecycle

    func start(username: String, password: String, domain: String?) {
        guard !terminated else { return }
        self.username = username
        self.password = password
        self.domain = domain
        connect()
    }

    func cancelled() {
        setStatus("Cancelled")
    }

    func failed(_ message: String) {
        setStatus(message)
    }

    func focus() {
        window?.makeFirstResponder(self)
    }

    func terminate() {
        terminated = true
        pendingResize?.cancel()
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        clipboardReady = false
        bridge?.detach()
        bridge = nil
        session?.close()
        session = nil
        isLive = false
        password = ""
    }

    private func connect() {
        let (width, height) = pixelSize()
        lastRequestedSize = (width, height)
        let bridge = RdpBridge(owner: self)
        self.bridge = bridge
        usesFastGraphics = RdpPreferences.fastGraphics
        let config = RdpConfig(
            host: connection.host,
            port: connection.port,
            username: username,
            password: password,
            domain: domain,
            width: UInt16(width),
            height: UInt16(height),
            scaleFactor: scalePercent(),
            acceptInvalidCerts: true,
            connectTimeoutSecs: 20,
            fastGraphics: usesFastGraphics,
            clipboard: RdpPreferences.shareClipboard
        )
        setStatus("Connecting to \(connection.host)…")
        session = RdpSession.connect(config: config, listener: bridge)
    }

    /// Pixels of remote desktop per point of this view.
    private var desktopScale: CGFloat {
        RdpPreferences.retina ? (window?.backingScaleFactor ?? 2) : 1
    }

    private func scalePercent() -> UInt32 {
        UInt32((desktopScale * 100).rounded())
    }

    /// The desktop size to ask for: this view's size in device pixels (or
    /// in points, with Retina resolution off), as the core will adjust it
    /// (within RDP's limits, width a multiple of 4). Using the core's rule
    /// keeps "wanted" equal to what the session actually requests, so a
    /// resize is never re-sent for a rounding gap.
    private func pixelSize() -> (Int, Int) {
        let scale = desktopScale
        let width = UInt32(min(max(bounds.width * scale, 0), 16384))
        let height = UInt32(min(max(bounds.height * scale, 0), 16384))
        let size = rdpDesktopSize(width: width, height: height)
        return (Int(size.width), Int(size.height))
    }

    /// Asks for a desktop of this view's size once the size has settled.
    /// The picture is scaled to fit in the meantime. While the window is
    /// being dragged the wait is longer, so the server is not asked for a
    /// new desktop at every step; the end of the drag asks at once.
    private func scheduleResize() {
        guard session != nil, isLive else { return }
        guard pixelSize() != lastRequestedSize else {
            pendingResize?.cancel()
            return
        }
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.requestResize() }
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inLiveResize ? 0.25 : 0.08), execute: work)
    }

    private func requestResize() {
        pendingResize?.cancel()
        guard let session, isLive else { return }
        let size = pixelSize()
        guard size != lastRequestedSize else { return }
        lastRequestedSize = size
        session.resize(width: UInt16(size.0), height: UInt16(size.1), scaleFactor: scalePercent())
    }

    private func preferencesChanged() {
        requestResize()
        if !RdpPreferences.shareClipboard, offeredChangeCount != nil {
            // Sharing was switched off: take back what was offered.
            offeredChangeCount = nil
            session?.clipboardOffer(hasText: false, files: [])
        }
        seenChangeCount = -1
        keyboardFocusChanged()
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
        status.isHidden = text.isEmpty
    }

    // MARK: Frames (called by the bridge on the main thread)

    func handleConnected(width: UInt16, height: UInt16, surfaceID: UInt32) {
        isLive = true
        setStatus("")
        frameWidth = Int(width)
        frameHeight = Int(height)
        incomingSurface = nil
        show(IOSurfaceLookup(surfaceID))
        // Some servers ignore the size asked for at connect; bring the desktop
        // to the pane's pixel size through Display Control.
        let wanted = pixelSize()
        if (Int(width), Int(height)) != wanted {
            lastRequestedSize = wanted
            session?.resize(width: UInt16(wanted.0), height: UInt16(wanted.1), scaleFactor: scalePercent())
        }
    }

    func handleResized(width: UInt16, height: UInt16, surfaceID: UInt32) {
        frameWidth = Int(width)
        frameHeight = Int(height)
        // Keep showing the old desktop until the new one has been painted.
        // A surface the session has already replaced again is not found;
        // its successor is on the way.
        incomingSurface = IOSurfaceLookup(surfaceID)
        if surface == nil {
            frameChanged()
        }
    }

    /// The session painted into its current surface.
    func frameChanged() {
        if let incoming = incomingSurface {
            incomingSurface = nil
            show(incoming)
        } else {
            show(surface)
        }
    }

    private func show(_ surface: IOSurfaceRef?) {
        self.surface = surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer only looks at the surface again when its contents are
        // set anew.
        surfaceLayer.contents = nil
        surfaceLayer.contents = surface
        CATransaction.commit()
    }

    func handleError(_ message: String) {
        lastError = message
        setStatus(message)
    }

    func handleClosed(_ reason: String, clean: Bool) {
        isLive = false
        session = nil
        clipboardReady = false
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        guard !terminated else { return }
        if clean {
            setStatus("Session ended: \(reason)")
            onSessionEnded?(true)
        } else {
            // Keep the specific error on screen; the close reason is generic.
            var text = lastError.map { "Disconnected: \($0)" } ?? "Disconnected: \(reason)"
            if usesFastGraphics {
                text += "\n\nIf this host keeps dropping the session, switch off View ▸ Remote Desktop ▸ Fast Graphics and reconnect."
            }
            setStatus(text)
            onSessionEnded?(false)
        }
    }

    func handleNotice(_ message: String) {
        noticeHide?.cancel()
        notice.stringValue = "  \(message)  "
        notice.isHidden = false
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice.isHidden = true }
        }
        noticeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: hide)
    }

    // MARK: Testing aids

    /// The surface on screen as an image, for `--snapshot`.
    func displayedImage() -> CGImage? {
        guard let surface else { return nil }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0, IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: rowBytes * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // BGRA in memory; the alpha byte is not meaningful.
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    var snapshotDescription: String {
        let shown = surface.map { "\(IOSurfaceGetWidth($0))x\(IOSurfaceGetHeight($0))" } ?? "none"
        return "live=\(isLive) desktop=\(frameWidth)x\(frameHeight) surface=\(shown) "
            + "waiting=\(incomingSurface != nil) asked=\(lastRequestedSize.0)x\(lastRequestedSize.1) "
            + "clipboardReady=\(clipboardReady) offered=\(offeredChangeCount != nil) "
            + "fastGraphics=\(usesFastGraphics) scale=\(scalePercent())%"
    }

    /// `--assume-keyboard`: treat live remote desktop panes as having the
    /// keyboard, for runs where the app cannot be frontmost (a locked
    /// screen, a headless check). Never set in normal use.
    private static let assumesKeyboard = CommandLine.arguments.contains("--assume-keyboard")

    // MARK: Clipboard

    /// This pane is where typing goes: its window is the key window of the
    /// active app and it is the first responder.
    private var hasKeyboard: Bool {
        guard let window else { return false }
        if Self.assumesKeyboard { return isLive }
        return NSApp.isActive && window.isKeyWindow && window.firstResponder === self
    }

    private func keyboardFocusChanged() {
        let watch = hasKeyboard && clipboardReady && RdpPreferences.shareClipboard && session != nil
        if watch {
            syncClipboard()
            if pasteboardTimer == nil {
                // macOS does not announce pasteboard changes; look while
                // this pane has the keyboard.
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncClipboard() }
                }
                RunLoop.main.add(timer, forMode: .common)
                pasteboardTimer = timer
            }
        } else {
            pasteboardTimer?.invalidate()
            pasteboardTimer = nil
        }
    }

    /// Announces the Mac's clipboard to the remote desktop when it has
    /// changed since this pane last looked, and otherwise fetches text the
    /// remote copied while the pane was in the background.
    private func syncClipboard() {
        guard let session, clipboardReady, RdpPreferences.shareClipboard, hasKeyboard else { return }
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != seenChangeCount {
            seenChangeCount = pasteboard.changeCount
            remoteTextWaiting = false
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let hasText = pasteboard.availableType(from: [.string]) != nil
            offeredChangeCount = (hasText || !urls.isEmpty) ? pasteboard.changeCount : nil
            session.clipboardOffer(hasText: hasText, files: urls.prefix(5000).map(\.path))
        } else if remoteTextWaiting {
            remoteTextWaiting = false
            session.clipboardFetchText()
        }
    }

    func handleClipboardReady() {
        clipboardReady = true
        seenChangeCount = -1
        keyboardFocusChanged()
    }

    /// The remote desktop is pasting: hand over the text, but only if the
    /// clipboard still holds what was announced. Something copied since
    /// then, in another app, was never offered to this remote.
    func handleClipboardTextRequested() {
        let pasteboard = NSPasteboard.general
        var text: String?
        if RdpPreferences.shareClipboard, let offered = offeredChangeCount, pasteboard.changeCount == offered {
            text = pasteboard.string(forType: .string)
        }
        session?.clipboardProvideText(text: text)
    }

    func handleClipboardRemoteChanged(hasText: Bool) {
        // The remote clipboard is the remote's own again.
        offeredChangeCount = nil
        remoteTextWaiting = false
        guard hasText, RdpPreferences.shareClipboard else { return }
        if hasKeyboard {
            session?.clipboardFetchText()
        } else {
            // Fetched when the pane next has the keyboard, unless the Mac's
            // clipboard has changed by then.
            remoteTextWaiting = true
        }
    }

    func handleClipboardText(_ text: String) {
        guard RdpPreferences.shareClipboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // This pane's own doing: not something to announce back.
        seenChangeCount = pasteboard.changeCount
        offeredChangeCount = nil
    }

    // MARK: Mouse

    private func remotePoint(_ event: NSEvent) -> (UInt16, UInt16)? {
        guard frameWidth > 0, frameHeight > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let x = Int((p.x / bounds.width * CGFloat(frameWidth)).rounded())
        let y = Int((p.y / bounds.height * CGFloat(frameHeight)).rounded())
        return (UInt16(min(max(x, 0), frameWidth - 1)), UInt16(min(max(y, 0), frameHeight - 1)))
    }

    private func sendMove(_ event: NSEvent) {
        guard let (x, y) = remotePoint(event) else { return }
        session?.mouseMove(x: x, y: y)
    }

    private func sendButton(_ event: NSEvent, _ button: RdpMouseButton, pressed: Bool) {
        if let (x, y) = remotePoint(event) {
            session?.mouseMove(x: x, y: y)
        }
        session?.mouseButton(button: button, pressed: pressed)
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(event, .left, pressed: true)
    }
    override func mouseUp(with event: NSEvent) { sendButton(event, .left, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { sendButton(event, .right, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { sendButton(event, .right, pressed: false) }

    override func otherMouseDown(with event: NSEvent) {
        sendButton(event, otherButton(event), pressed: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        sendButton(event, otherButton(event), pressed: false)
    }

    private func otherButton(_ event: NSEvent) -> RdpMouseButton {
        switch event.buttonNumber {
        case 3: return .x1
        case 4: return .x2
        default: return .middle
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let (x, y) = remotePoint(event) {
            session?.mouseMove(x: x, y: y)
        }
        // RDP counts wheel notches in units of 120; trackpads deliver fine deltas.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 120
        let dy = Int(event.scrollingDeltaY * factor)
        let dx = Int(event.scrollingDeltaX * factor)
        if dy != 0 { session?.scroll(vertical: true, units: Int16(clamping: dy)) }
        if dx != 0 { session?.scroll(vertical: false, units: Int16(clamping: -dx)) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if let sc = MacKeyCodes.scancode(forKeyCode: event.keyCode) {
            session.key(scancode: sc.code, extended: sc.extended, pressed: true)
        } else if let chars = event.characters {
            for scalar in chars.unicodeScalars {
                session.unicode(codePoint: scalar.value, pressed: true)
                session.unicode(codePoint: scalar.value, pressed: false)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let sc = MacKeyCodes.scancode(forKeyCode: event.keyCode) else { return }
        session?.key(scancode: sc.code, extended: sc.extended, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let session, let sc = MacKeyCodes.scancode(forKeyCode: event.keyCode) else {
            modifierFlags = event.modifierFlags
            return
        }
        let mask = modifierMask(for: event.keyCode)
        let pressed = event.modifierFlags.contains(mask)
        session.key(scancode: sc.code, extended: sc.extended, pressed: pressed)
        modifierFlags = event.modifierFlags
    }

    private func modifierMask(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        case 0x39: return .capsLock
        default: return []
        }
    }

    /// Keeps ⌘-shortcuts for the remote session rather than the local menu,
    /// except the ones that manage panes and workspaces. Only while this
    /// pane has the keyboard: AppKit offers a key equivalent to every view
    /// in the key window, first responder or not, before the menu sees it,
    /// so without that check a live desktop took ⌘V, ⌘C, ⌘A and the rest
    /// away from the sidebar's filter and every other field in its window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isLive, window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        let reserved: Set<String> = ["t", "w", "n", "d", "q", "r", "[", "]", ",", "h", "m"]
        if let chars = event.charactersIgnoringModifiers?.lowercased(), reserved.contains(chars) {
            return false
        }
        keyDown(with: event)
        return true
    }
}

/// Core callbacks arrive on the session's thread and are passed to the main
/// thread. Frame updates are coalesced: however many regions the session
/// painted, the layer is refreshed once per main-thread turn.
final class RdpBridge: RdpListener, @unchecked Sendable {
    private weak var owner: RdpSessionView?
    private let lock = NSLock()
    private var frameDirty = false
    private var flushScheduled = false
    /// Counts desktop sizes, so a refresh queued for an earlier surface
    /// does not run ahead of the news of the next one.
    private var generation = 0

    init(owner: RdpSessionView) {
        self.owner = owner
    }

    func detach() {
        lock.lock()
        owner = nil
        lock.unlock()
    }

    private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }

    private func currentOwner() -> RdpSessionView? {
        lock.lock()
        defer { lock.unlock() }
        return owner
    }

    private func newSurface() {
        lock.lock()
        generation += 1
        frameDirty = false
        flushScheduled = false
        lock.unlock()
    }

    func onConnected(width: UInt16, height: UInt16, surfaceId: UInt32) {
        newSurface()
        onMain { [self] in currentOwner()?.handleConnected(width: width, height: height, surfaceID: surfaceId) }
    }

    func onDesktopResized(width: UInt16, height: UInt16, surfaceId: UInt32) {
        newSurface()
        onMain { [self] in currentOwner()?.handleResized(width: width, height: height, surfaceID: surfaceId) }
    }

    func onRegionUpdated(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        lock.lock()
        frameDirty = true
        let schedule = !flushScheduled
        flushScheduled = true
        let scheduledFor = generation
        lock.unlock()
        if schedule {
            onMain { [self] in flush(scheduledFor) }
        }
    }

    @MainActor
    private func flush(_ scheduledFor: Int) {
        lock.lock()
        guard scheduledFor == generation else {
            lock.unlock()
            return
        }
        let dirty = frameDirty
        frameDirty = false
        flushScheduled = false
        let owner = owner
        lock.unlock()
        if dirty { owner?.frameChanged() }
    }

    func onError(message: String) {
        onMain { [self] in currentOwner()?.handleError(message) }
    }

    func onClosed(reason: String, clean: Bool) {
        onMain { [self] in currentOwner()?.handleClosed(reason, clean: clean) }
    }

    func onClipboardReady() {
        onMain { [self] in currentOwner()?.handleClipboardReady() }
    }

    func onClipboardRemoteChanged(hasText: Bool) {
        onMain { [self] in currentOwner()?.handleClipboardRemoteChanged(hasText: hasText) }
    }

    func onClipboardText(text: String) {
        onMain { [self] in currentOwner()?.handleClipboardText(text) }
    }

    func onClipboardTextRequested() {
        onMain { [self] in currentOwner()?.handleClipboardTextRequested() }
    }

    func onNotice(message: String) {
        onMain { [self] in currentOwner()?.handleNotice(message) }
    }
}
