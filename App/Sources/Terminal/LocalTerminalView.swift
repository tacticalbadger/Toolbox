import AppKit
import Darwin
import SwiftTerm

/// A terminal pane running the user's login shell on this Mac.
///
/// The engine is the one the SSH panes use (SwiftTerm), here in its
/// local-process form: a pseudo-terminal with the shell behind it and the
/// output parsed off the main thread. iTerm2 was asked for and looked at:
/// it is GPL (which the app's proprietary license cannot take in) and has
/// no form that can be embedded, short of carrying a modified copy of its
/// source the way Royal TSX's plugin does.
final class LocalTerminalView: NSView, PaneContent, LocalProcessTerminalViewDelegate {
    private let terminal: LocalProcessTerminalView
    private let shell = LocalShell.current
    /// `terminalDelegate` is weak; this keeps the policy alive.
    private let policy: LocalTerminalPolicy
    private let outputSignal = MainThreadSignal(interval: 0.3)
    private var launched = false
    private var launchedAt = Date.distantPast
    private var terminated = false
    private var metalEnabled = false

    /// The title a program in the terminal asked for (OSC 0 / 2), if any,
    /// and whether the shell itself was in the foreground when it did. A
    /// title set by something that ran in the shell (`ssh` passing on a
    /// remote prompt's, an editor's) is dropped when the shell is back, or
    /// the tab would keep naming a host that was left long ago.
    private var programTitle = ""
    private var programTitleIsTheShells = false
    /// The working directory and the name of what runs in the foreground,
    /// read from the system: no shell integration is needed for either.
    private var directory: String
    private var foreground: String
    private var foregroundIsShell = true

    // MARK: PaneContent

    var view: NSView { self }
    private(set) var title: String
    private(set) var tabTitle: String
    private(set) var isLive = false {
        didSet { onStateChange?() }
    }
    var onTitleChange: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onFocus: (() -> Void)?
    var onSessionEnded: ((Bool) -> Void)?

    /// An idle shell closes without a question, as in Terminal; a program
    /// in the foreground is named first. Background jobs are not looked
    /// for: they end with the shell, as they do when a Terminal window is
    /// closed.
    var closeWarning: String? {
        guard isLive else { return nil }
        refreshProcessInfo()
        return foregroundIsShell ? nil : "“\(foreground)” is still running in this terminal."
    }

    init() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                            font: nil,
                                            options: TerminalOptions(scrollback: 10_000))
        policy = LocalTerminalPolicy(terminal)
        directory = shell.home
        foreground = shell.name
        title = ""
        tabTitle = ""
        super.init(frame: .zero)
        (title, tabTitle) = composedTitles()

        terminal.processDelegate = self
        terminal.terminalDelegate = policy
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        ThemeStore.shared.apply(to: terminal)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: ThemeStore.changed, object: nil)

        // Output is the moment the directory or the foreground program may
        // have changed (a prompt came back, a command was echoed).
        outputSignal.action = { [weak self] in self?.refreshProcessInfo() }
        terminal.setProcessOutputHandler { [outputSignal] in outputSignal.raise() }

        // Normally the first layout starts the shell (see `layout`); a pane
        // that is not laid out, in a tab that is not showing, still gets one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        // Started once the pane has its size, so the shell draws its first
        // prompt for the right number of columns.
        if !launched, window != nil, bounds.width > 1, bounds.height > 1 {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.launch() }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !metalEnabled else { return }
        do {
            try terminal.setUseMetal(true)
            metalEnabled = true
        } catch {
            NSLog("Metal renderer unavailable, staying on CoreGraphics: \(error)")
        }
    }

    @objc private func themeChanged() {
        ThemeStore.shared.apply(to: terminal)
    }

    func focus() {
        window?.makeFirstResponder(terminal)
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        outputSignal.action = nil
        terminal.setProcessOutputHandler(nil)
        if launched, let process = terminal.process, process.running {
            // A closing terminal is a hangup: the shell passes it on to its
            // jobs and exits. SIGTERM alone would not do, an interactive
            // shell ignores it. Whatever survives both is killed when the
            // view is released (SwiftTerm escalates).
            let pid = process.shellPid
            if pid > 0 { kill(pid, SIGHUP) }
            terminal.terminate()
        }
        isLive = false
    }

    // MARK: The shell

    private func launch() {
        guard !launched, !terminated else { return }
        launched = true
        launchedAt = Date()
        isLive = true
        // A leading dash in argv[0] makes it a login shell, which is what
        // sets up PATH and the rest of the user's environment in an app
        // that Finder started with next to nothing.
        terminal.startProcess(executable: shell.path, args: [], environment: shell.environment(),
                              execName: "-" + shell.name, currentDirectory: shell.home)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshProcessInfo() }
        }
    }

    /// Sends text to the shell as if it had been typed (`--demo-type`).
    func type(_ text: String) {
        terminal.send(txt: text)
    }

    /// For `--snapshot`: what the pane says about itself, and the screen's
    /// text.
    var snapshotDescription: String {
        "live=\(isLive) title=\(title) tab=\(tabTitle) foregroundIsShell=\(foregroundIsShell)"
    }

    var screenText: String {
        String(decoding: terminal.getBufferAsData(), as: UTF8.self)
    }

    private func note(_ text: String, color: Int = 2) {
        terminal.feed(text: "\r\n\u{1b}[\(color)m\(text)\u{1b}[0m\r\n")
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        programTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        programTitleIsTheShells = true
        // Settles who set it, and drops it again if that was a program
        // which has already gone.
        refreshProcessInfo()
        programTitleIsTheShells = foregroundIsShell
        updateTitles()
    }

    /// OSC 7. Not used: the directory is read from the system, which also
    /// works for shells that send nothing, and a remote host reached with
    /// `ssh` from this terminal sends its own paths this way.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isLive = false
        guard !terminated else { return }
        let ranFor = Date().timeIntervalSince(launchedAt)
        switch exitCode {
        case .some(let code) where code == 0 || ranFor >= 1:
            // `exit` hands back the status of the last command, so a shell
            // that was used and left is a clean end whatever the number.
            note("[Session ended]")
            onSessionEnded?(true)
        case .some(let code):
            note("[\(shell.path) ended with status \(code) right after starting]", color: 31)
            onSessionEnded?(false)
        case .none:
            note("[The shell was ended by a signal]", color: 31)
            onSessionEnded?(false)
        }
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        isLive = false
        guard !terminated else { return }
        onSessionEnded?(false)
    }

    // MARK: Titles

    /// Asks the system what the terminal is doing: the foreground process
    /// group of the pseudo-terminal, that process's name and its working
    /// directory.
    private func refreshProcessInfo() {
        guard isLive, let process = terminal.process else { return }
        let shellPid = process.shellPid, descriptor = process.childfd
        guard shellPid > 0, descriptor >= 0 else { return }
        let group = tcgetpgrp(descriptor)
        let leader = group > 0 ? group : shellPid
        foregroundIsShell = leader == shellPid
        foreground = foregroundIsShell ? shell.name : (ProcessInfoQuery.name(of: leader) ?? shell.name)
        if foregroundIsShell, !programTitleIsTheShells { programTitle = "" }
        if let path = ProcessInfoQuery.workingDirectory(of: leader) ?? ProcessInfoQuery.workingDirectory(of: shellPid) {
            directory = path
        }
        updateTitles()
    }

    private func updateTitles() {
        let (newTitle, newTabTitle) = composedTitles()
        guard newTitle != title || newTabTitle != tabTitle else { return }
        title = newTitle
        tabTitle = newTabTitle
        onTitleChange?(newTitle)
    }

    /// The pane's header shows the whole path, the tab its last folder:
    /// "~/code/Toolbox — zsh" and "Toolbox — zsh". A title the program set
    /// replaces both.
    private func composedTitles() -> (title: String, tab: String) {
        if !programTitle.isEmpty { return (programTitle, programTitle) }
        var shown = directory
        if shown == shell.home {
            shown = "~"
        } else if shown.hasPrefix(shell.home + "/") {
            shown = "~" + shown.dropFirst(shell.home.count)
        }
        let leaf = shown == "~" || shown == "/" ? shown : (shown as NSString).lastPathComponent
        return ("\(shown) — \(foreground)", "\(leaf) — \(foreground)")
    }
}

// MARK: - What programs in the terminal may do

/// `LocalProcessTerminalView` is its own terminal delegate and answers a
/// clipboard query (OSC 52 with `?`) with what is on the Mac's clipboard.
/// Anything that can print to the terminal can ask: a file shown with
/// `cat`, a server at the other end of `ssh`. This stands in front of the
/// view, refuses that one request and passes everything else through
/// unchanged. Writing to the clipboard stays allowed, as in the SSH panes.
@MainActor
private final class LocalTerminalPolicy: TerminalViewDelegate {
    private weak var view: LocalProcessTerminalView?

    init(_ view: LocalProcessTerminalView) {
        self.view = view
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view?.scrolled(source: source, position: position)
    }

    /// Links go through SwiftTerm's own check of untrusted terminal output
    /// (web links open, anything that could start a program asks first).
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        view?.requestOpenLink(source: source, request: request)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        view?.clipboardCopy(source: source, content: content)
    }

    // The newer clipboard protocol (OSC 5522) is the view's to answer. It
    // asks its process delegate, which grants nothing, so programs are told
    // the protocol is not there; ⌘V goes the same way and still pastes.

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        view?.kittyClipboardCapabilities(source: source) ?? []
    }

    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? {
        view?.kittyClipboardAvailableMimeTypes(source: source, location: location)
    }

    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation,
                            mimeType: String) -> KittyClipboardReadResult? {
        view?.kittyClipboardRead(source: source, location: location, mimeType: mimeType)
    }

    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation,
                             content: KittyClipboardWriteContent) -> KittyClipboardWriteResult {
        view?.kittyClipboardWrite(source: source, location: location, content: content) ?? .unsupported
    }

    func kittyClipboardRequestPermission(source: TerminalView,
                                         request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
        view?.kittyClipboardRequestPermission(source: source, request: request) ?? .deny
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view?.rangeChanged(source: source, startY: startY, endY: endY)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        view?.programStatusChanged(source: source, records: records)
    }
}

// MARK: - The user's shell

/// The login shell and home folder from the user's account record, which
/// is where Terminal takes them from, and the environment to start it in.
struct LocalShell {
    let path: String
    let home: String
    let user: String

    /// "zsh"
    var name: String { (path as NSString).lastPathComponent }

    static var current: LocalShell {
        var path = "/bin/zsh"
        var home = NSHomeDirectory()
        var user = NSUserName()
        if let record = getpwuid(getuid()) {
            if let shell = record.pointee.pw_shell {
                let candidate = String(cString: shell)
                if FileManager.default.isExecutableFile(atPath: candidate) { path = candidate }
            }
            if let directory = record.pointee.pw_dir { home = String(cString: directory) }
            if let name = record.pointee.pw_name { user = String(cString: name) }
        }
        return LocalShell(path: path, home: home, user: user)
    }

    /// What the app was started with, less what is meant for the app alone,
    /// plus what a terminal is expected to say about itself.
    func environment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = inherited.filter { !$0.key.hasPrefix("TOOLBOX_") }
        for stale in ["PWD", "OLDPWD", "TERM_SESSION_ID", "TERMCAP", "COLUMNS", "LINES"] { env[stale] = nil }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Toolbox"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        env["SHELL"] = path
        env["HOME"] = home
        env["USER"] = user
        env["LOGNAME"] = user
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil {
            env["LANG"] = Self.locale
        }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// A UTF-8 locale for programs in the shell: the system's language and
    /// region when macOS has a locale by that name ("en_DE" has none), else
    /// en_US. Without one, programs fall back to ASCII.
    static var locale: String {
        let current = Locale.current
        if let language = current.language.languageCode?.identifier, let region = current.region?.identifier {
            let name = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") { return name }
        }
        return "en_US.UTF-8"
    }
}

/// Facts about another process of the same user, from libproc.
enum ProcessInfoQuery {
    static func name(of pid: pid_t) -> String? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: &info.pbsi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return name.isEmpty ? nil : name
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return path.isEmpty ? nil : path
    }
}

/// Turns a burst of calls from any thread into one call on the main thread,
/// at most once per interval.
final class MainThreadSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private let interval: TimeInterval
    /// Set and cleared on the main thread.
    var action: (@MainActor () -> Void)?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func raise() {
        lock.lock()
        let schedule = !pending
        pending = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = false
            self.lock.unlock()
            MainActor.assumeIsolated { self.action?() }
        }
    }
}
