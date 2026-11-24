import AppKit

/// Testing aid behind `--snapshot <dir>`: pictures of the app's windows,
/// drawn by the app itself. Unlike a screenshot it needs no Screen Recording
/// permission and works with the screen locked. Remote desktop panes are
/// saved separately, straight from the surface they display, because a
/// layer showing a surface does not draw into a bitmap.
@MainActor
enum Snapshot {
    static func write(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var desktops = 0
        var report: [String] = []
        defer { save(report.joined(separator: "\n").data(using: .utf8), as: "snapshot.txt", in: directory) }
        func note(_ line: String) {
            NSLog("snapshot: \(line)")
            report.append(line)
        }
        // Every workspace tab with what is in it, whichever one is showing.
        // For a local terminal that includes the last lines on its screen,
        // which is how a run without a screenshot can tell that the shell
        // answered; like the pictures below, not something to produce from
        // the owner's own sessions.
        let workspaces = (NSApp.delegate as? AppDelegate)?.workspaces ?? []
        for (index, workspace) in workspaces.enumerated() {
            let window = workspace.window
            let sessions = workspace.paneVC.contents.map { "\(type(of: $0)):\($0.tabTitle)\($0.isLive ? "" : " (not live)")" }
            note("workspace-\(index + 1) title=\(window?.title ?? "") panes=\(workspace.paneVC.paneCount) "
                + "sessions=[\(sessions.joined(separator: " | "))] "
                + "tabs=\(window?.tabbedWindows?.count ?? 1) selected=\(window?.tabGroup?.selectedWindow === window) "
                + "onScreen=\(window?.occlusionState.contains(.visible) == true) "
                + "filter=\(workspace.sidebar.filterText)")
            for case let files as SftpPaneView in workspace.paneVC.contents {
                note("  files connected=\(files.model.isConnected) status=\(files.model.status ?? "")")
            }
            for case let terminal as LocalTerminalView in workspace.paneVC.contents {
                note("  terminal \(terminal.snapshotDescription)")
                let lines = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for line in lines.suffix(12) { note("  | \(line)") }
            }
        }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = "window-\(index).png"
            save(bitmap.representation(using: .png, properties: [:]), as: name, in: directory)
            note("\(name) \(Int(view.bounds.width))x\(Int(view.bounds.height)) \(type(of: window)) title=\(window.title)")
            for pane in remoteDesktops(in: view) {
                desktops += 1
                let name = "desktop-\(desktops).png"
                let image = pane.displayedImage()
                if let image {
                    save(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), as: name, in: directory)
                }
                note("\(name) \(pane.snapshotDescription) saved=\(image != nil)")
            }
        }
    }

    private static func save(_ data: Data?, as name: String, in directory: URL) {
        guard let data else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }

    private static func remoteDesktops(in view: NSView) -> [RdpSessionView] {
        var found: [RdpSessionView] = []
        if let pane = view as? RdpSessionView { found.append(pane) }
        for child in view.subviews { found += remoteDesktops(in: child) }
        return found
    }
}
