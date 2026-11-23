import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var controllers: [WorkspaceWindowController] = []
    private var tabClickMonitor: Any?

    var workspaces: [WorkspaceWindowController] { controllers }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RdpPreferences.registerDefaults()
        MainMenu.install()
        _ = AppModel.shared
        // Double-clicking a workspace tab renames it. The first click of the
        // pair has already selected the tab, so the key window is the one.
        tabClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, Self.isOnWorkspaceTab(event) else { return event }
            DispatchQueue.main.async {
                (NSApp.keyWindow?.windowController as? WorkspaceWindowController)?.renameWorkspace(nil)
            }
            return nil
        }
        let controller = newWorkspaceWindow(asTab: false)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            // Providers with auto-refresh run at launch, then on their timers.
            await ProviderSync.shared.syncAll(automatic: true)
            ProviderSync.shared.scheduleAutoRefresh()
            self.openConnectionFromArguments(in: controller)
        }
    }

    /// Whether a click landed on the window's tab bar. The bar is private
    /// AppKit (NSTabBar draws the tabs itself; the "+" is an
    /// NSTabBarNewTabButton inside it), so this goes by class name.
    private static func isOnWorkspaceTab(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.windowController is WorkspaceWindowController,
              let frameView = window.contentView?.superview else { return false }
        var view = frameView.hitTest(event.locationInWindow)
        var onTabBar = false
        while let current = view {
            let name = String(describing: type(of: current))
            if name.contains("NewTab") { return false }
            if name.contains("TabBar") { onTabBar = true }
            view = current.superview
        }
        return onTabBar
    }

    @objc func syncProviders(_ sender: Any?) {
        Task { @MainActor in
            await ProviderSync.shared.syncAll(automatic: false)
        }
    }

    @objc func lockVault(_ sender: Any?) {
        VaultManager.shared.lock()
    }

    @objc func toggleVaultAuthentication(_ sender: Any?) {
        VaultManager.shared.requiresAuthentication.toggle()
    }

    /// The View ▸ Remote Desktop switches; each item carries its
    /// `RdpPreferences` key.
    @objc func toggleRemoteDesktopPreference(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        RdpPreferences.toggle(key)
    }

    /// `Toolbox --connect <name or id>` opens that connection on launch;
    /// `--files <name or id>` opens its SFTP browser.
    private func openConnectionFromArguments(in controller: WorkspaceWindowController) {
        let args = CommandLine.arguments
        for (index, flag) in args.enumerated() where index + 1 < args.count {
            let wanted = args[index + 1]
            let action: ((Connection) -> Void)?
            switch flag {
            case "--connect": action = { controller.open($0) }
            case "--files": action = { controller.openFiles($0) }
            default: action = nil
            }
            guard let action else { continue }
            guard let connection = AppModel.shared.connections.first(where: { $0.id == wanted || $0.name == wanted }) else {
                NSLog("\(flag): no connection named \(wanted)")
                continue
            }
            action(connection)
        }
        // Testing aid: save pictures of the app's windows, drawn by the app
        // itself, a few seconds after launch (`--snapshot-after <secs>`).
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            let delay = args.firstIndex(of: "--snapshot-after").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Snapshot.write(to: directory)
            }
        }
        // Testing aid: split the focused pane shortly after launch, which
        // resizes what is in it.
        if args.contains("--demo-split") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                controller.splitRight(nil)
            }
        }
        // Testing aid: move the focused pane into a fresh workspace tab.
        if args.contains("--demo-move") {
            controller.movePaneToNewWorkspace(nil)
        }
        // Testing aid: close the focused pane shortly after launch, the way
        // its × button would.
        if args.contains("--demo-close") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                controller.paneVC.closePane(controller.paneVC.focusedPane.id)
            }
        }
        // Testing aids: open an editor sheet straight away.
        if let index = args.firstIndex(of: "--edit-connection"), index + 1 < args.count {
            let wanted = args[index + 1]
            controller.edit(wanted == "new" ? nil : AppModel.shared.connections.first { $0.id == wanted || $0.name == wanted })
        }
        if let index = args.firstIndex(of: "--edit-provider"), index + 1 < args.count {
            let wanted = args[index + 1]
            controller.editProvider(wanted == "new" ? nil : AppModel.shared.providers.first { $0.id == wanted || $0.name == wanted })
        }
        // Testing aid: exercise a provider-owned account's save and removal.
        if let index = args.firstIndex(of: "--demo-provider-account"), index + 1 < args.count,
           let provider = AppModel.shared.providers.first(where: { $0.id == args[index + 1] }) {
            Task { @MainActor in
                do {
                    var draft = ProviderDraft(provider)
                    draft.bind = RoleCredentialDraft(mode: .specify, username: "CORP\\svc-toolbox", password: "fixture-password")
                    try await AppModel.shared.saveProvider(draft)
                    let managed = AppModel.shared.managedCredentials(of: provider.id)
                    let secret = try VaultManager.shared.vault.getSecret(id: ProviderRole.bind.managedId(provider: provider.id))
                    NSLog("provider-account: saved; managed=\(managed.map(\.id)) folder=\(managed.first?.folder ?? "-") vaultPasswordStored=\(secret.password == "fixture-password")")
                    draft = ProviderDraft(AppModel.shared.provider(provider.id)!)
                    NSLog("provider-account: reloaded draft mode=\(draft.bind.mode.rawValue) hasStored=\(draft.bind.hasStored)")
                    draft.bind = RoleCredentialDraft(mode: .existing, credentialId: "op-fake:i1")
                    try await AppModel.shared.saveProvider(draft)
                    let after = AppModel.shared.managedCredentials(of: provider.id)
                    let bindNow = AppModel.shared.provider(provider.id).flatMap { p -> String? in
                        if case .activeDirectory(_, _, let bind, _, _, _, _) = p.kind { return bind }
                        return nil
                    }
                    let gone = (try? VaultManager.shared.vault.getSecret(id: ProviderRole.bind.managedId(provider: provider.id))) == nil
                    NSLog("provider-account: switched; managed=\(after.map(\.id)) bind=\(bindNow ?? "-") vaultSecretRemoved=\(gone)")
                } catch {
                    NSLog("provider-account: failed: \(describe(error))")
                }
            }
        }
        // Testing aid: rename a provider the way its editor would, shortly
        // after launch, and log where its folder went (or why it stayed).
        if let index = args.firstIndex(of: "--demo-provider-rename"), index + 2 < args.count {
            let wanted = args[index + 1], name = args[index + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Task { @MainActor in
                    guard let provider = AppModel.shared.provider(wanted) else {
                        NSLog("provider-rename: no provider with id \(wanted)")
                        return
                    }
                    var draft = ProviderDraft(provider)
                    draft.name = name
                    if let problem = draft.validationError {
                        NSLog("provider-rename: refused by the editor: \(problem)")
                        return
                    }
                    do {
                        let stored = try await AppModel.shared.saveProvider(draft)
                        NSLog("provider-rename: \(provider.folder) -> \(stored.folder), named \(stored.name)")
                    } catch {
                        NSLog("provider-rename: refused: \(describe(error))")
                    }
                }
            }
        }
        // Testing aid: rename or move a folder shortly after launch.
        if let index = args.firstIndex(of: "--demo-folder-rename"), index + 2 < args.count {
            let from = args[index + 1], to = args[index + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                do {
                    try AppModel.shared.renameFolder(from, to: to)
                    NSLog("folder-rename: \(from) -> \(to)")
                } catch {
                    NSLog("folder-rename: refused: \(describe(error))")
                }
            }
        }
        if let index = args.firstIndex(of: "--set-folder-credential"), index + 1 < args.count {
            controller.setFolderCredential(args[index + 1])
        }
        // Testing aid: unlock the vault right away and log how it went.
        if args.contains("--unlock-vault") {
            Task { @MainActor in
                do {
                    _ = try await VaultManager.shared.unlockedVault()
                    NSLog("vault unlocked")
                } catch {
                    NSLog("vault unlock failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            newWorkspaceWindow(asTab: false)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = controllers.reduce(0) { $0 + $1.paneVC.liveSessionCount }
        if live > 0,
           !Prompts.confirm(title: "Quit Toolbox?",
                            message: "\(live) active session\(live == 1 ? "" : "s") will be disconnected.",
                            ok: "Quit") {
            return .terminateCancel
        }
        controllers.forEach { $0.paneVC.terminateAll() }
        return .terminateNow
    }

    // MARK: Workspaces

    @objc func newWorkspace(_ sender: Any?) {
        newWorkspaceWindow(asTab: true)
    }

    /// AppKit sends this when the "+" button in the native tab bar is clicked.
    @objc func newWindowForTab(_ sender: Any?) {
        newWorkspaceWindow(asTab: true)
    }

    @discardableResult
    func newWorkspaceWindow(asTab: Bool) -> WorkspaceWindowController {
        WorkspaceWindowController.counter += 1
        let controller = WorkspaceWindowController(name: "Workspace \(WorkspaceWindowController.counter)")
        controllers.append(controller)
        if asTab,
           let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let window = controller.window,
           key.tabbingIdentifier == window.tabbingIdentifier {
            key.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // Workspaces are tabs; keep the bar visible so the "+" is always there.
        if let window = controller.window, let group = window.tabGroup, !group.isTabBarVisible {
            window.toggleTabBar(nil)
        }
        return controller
    }

    /// Fills the "Move Pane to Workspace" submenu with the other workspaces.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = (NSApp.keyWindow?.windowController as? WorkspaceWindowController)
            ?? (NSApp.mainWindow?.windowController as? WorkspaceWindowController)
        for workspace in controllers where workspace !== current {
            let item = NSMenuItem(title: workspace.window?.title ?? "Workspace",
                                  action: #selector(WorkspaceWindowController.movePaneToWorkspace(_:)),
                                  keyEquivalent: "")
            item.representedObject = workspace
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No Other Workspaces", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    func windowControllerDidClose(_ controller: WorkspaceWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: App menu

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Toolbox",
            .version: "core \(coreVersion())",
        ])
    }

    // MARK: View menu

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let theme = TerminalTheme.all.first(where: { $0.id == id }) else { return }
        ThemeStore.shared.current = theme
    }

    @objc func increaseFontSize(_ sender: Any?) { ThemeStore.shared.fontSize += 1 }
    @objc func decreaseFontSize(_ sender: Any?) { ThemeStore.shared.fontSize -= 1 }
    @objc func resetFontSize(_ sender: Any?) { ThemeStore.shared.fontSize = ThemeStore.defaultFontSize }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTheme(_:)) {
            let id = menuItem.representedObject as? String
            menuItem.state = id == ThemeStore.shared.current.id ? .on : .off
        }
        if menuItem.action == #selector(toggleVaultAuthentication(_:)) {
            menuItem.state = VaultManager.shared.requiresAuthentication ? .on : .off
        }
        if menuItem.action == #selector(toggleRemoteDesktopPreference(_:)), let key = menuItem.representedObject as? String {
            menuItem.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        }
        return true
    }
}
