import AppKit

/// Testing aid behind `--demo-filter-paste <connection id>`: presses ⌘V the
/// way the keyboard would (see `ShortcutPress`) and logs where it went.
///
/// 1. With the keyboard in the sidebar's filter and no session open.
/// 2. The same with the connection open. AppKit offers a key equivalent to
///    every view in the key window before the menu sees it, so a pane that
///    takes shortcuts it has no business with shows up here as a paste that
///    never reaches the field (a live remote desktop pane did exactly that
///    up to 0.3.1: "I can only paste into the filter once").
/// 3. With the keyboard in the session's pane: the filter must stay as it
///    is, and the shortcut is the session's (a remote desktop gets the key,
///    which the test server counts as `keys=` in its log; a terminal gets
///    the text).
/// 4. A second session is opened (a local terminal). It gets a tab of its
///    own, and the sidebar in it must look like the one it was opened
///    from: filter, open folders, selection, place in the list, width.
///
/// The app has to be frontmost for this to mean anything: without a key
/// window the menu's Paste has nowhere to go either.
@MainActor
enum FilterPasteCheck {
    static func run(in workspace: WorkspaceWindowController, connection: Connection) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            workspace.sidebar.focusFilter()
            pressCommandV(pasting: "first-paste", in: workspace)
            report("before the session", expecting: "first-paste", in: workspace)
            workspace.open(connection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                workspace.sidebar.focusFilter()
                pressCommandV(pasting: "second-paste", in: workspace)
                report("with the session open", expecting: "second-paste", in: workspace)
                // The session opened where new sessions go, which may be
                // another tab: press the key there.
                guard let session = (NSApp.delegate as? AppDelegate)?.workspaces
                    .first(where: { $0.paneVC.liveSessionCount > 0 }) else {
                    NSLog("filter-paste: keyboard in the session: no live session to try")
                    return
                }
                session.window?.makeKeyAndOrderFront(nil)
                session.paneVC.focusedPane.focus()
                let before = session.sidebar.filterText
                pressCommandV(pasting: "third-paste", in: session)
                NSLog("filter-paste: keyboard in the session: filter untouched=\(session.sidebar.filterText == before)")
                // 4. A second session gets a tab of its own, and the
                //    sidebar there carries on with the same filter.
                //    To have more than a filter to compare, the first
                //    sidebar gets a filter that leaves a long list (every
                //    folder is open while one is set), a selection, and is
                //    scrolled down.
                var view = session.sidebar.viewState
                view.filter = "o"
                view.selected = ["conn:\(connection.id)"]
                view.scrollOrigin.y = 120
                session.sidebar.adopt(view)
                let count = (NSApp.delegate as? AppDelegate)?.workspaces.count ?? 0
                // A local terminal: a second connection to the same test
                // server would end the first one.
                session.openLocalTerminal()
                // Compared once the new sidebar has settled (it rebuilds
                // itself once more after it appears).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let all = (NSApp.delegate as? AppDelegate)?.workspaces ?? []
                    guard let newest = all.last, newest !== session else {
                        NSLog("filter-paste: second session: no new tab (workspaces \(count) -> \(all.count))")
                        return
                    }
                    let from = session.sidebar.viewState, to = newest.sidebar.viewState
                    NSLog("filter-paste: second session: workspaces \(count) -> \(all.count), "
                        + "filter carried over=\(to.filter == from.filter) (\"\(to.filter)\") "
                        + "open folders=\(to.expanded == from.expanded) (\(from.expanded.count) -> \(to.expanded.count)) "
                        + "selection=\(to.selected == from.selected) (\(to.selected.count)) "
                        + "scroll=\(to.scrollOrigin == from.scrollOrigin) (\(Int(from.scrollOrigin.y)) -> \(Int(to.scrollOrigin.y))) "
                        + "width=\(Int(session.sidebar.view.frame.width)) -> \(Int(newest.sidebar.view.frame.width))")
                }
            }
        }
    }

    private static func pressCommandV(pasting text: String, in workspace: WorkspaceWindowController) {
        guard let window = workspace.window else { return }
        // Paste reads the real clipboard: keep what it holds and put it
        // back before this returns.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.savedItems()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ShortcutPress.command("v", in: window)
        pasteboard.restore(saved)
    }

    private static func report(_ step: String, expecting text: String, in workspace: WorkspaceWindowController) {
        let got = workspace.sidebar.filterText
        let live = (NSApp.delegate as? AppDelegate)?.workspaces.reduce(0) { $0 + $1.paneVC.liveSessionCount } ?? 0
        NSLog("filter-paste: \(step): active=\(NSApp.isActive) key=\(workspace.window?.isKeyWindow == true) "
            + "live=\(live) field=\"\(got)\" pasted=\(got == text)")
    }
}

private extension NSPasteboard {
    /// Every item with every representation it offers.
    func savedItems() -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboardItems ?? []).map { item in
            var saved: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { saved[type] = data }
            }
            return saved
        }
    }

    func restore(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        clearContents()
        guard !items.isEmpty else { return }
        writeObjects(items.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        })
    }
}
