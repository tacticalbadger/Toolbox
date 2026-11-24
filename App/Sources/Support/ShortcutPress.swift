import AppKit

/// Testing aid: a ⌘ shortcut, for checks of what a shortcut reaches. A
/// capital letter adds ⇧.
@MainActor
enum ShortcutPress {
    /// Virtual key codes of the letters on an ANSI keyboard.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
    ]

    private static func modifiers(for key: Character) -> NSEvent.ModifierFlags {
        key.isUppercase ? [.command, .shift] : .command
    }

    /// Presses ⌘ and `key` the way the keyboard would, through
    /// `NSApp.sendEvent`, so it takes the route a real one takes: every
    /// view of the key window is offered it first, then the menu. Only an
    /// app in front has a key window; returns whether there was one (or a
    /// window was named).
    @discardableResult
    static func command(_ key: Character, in window: NSWindow? = nil) -> Bool {
        guard let window = window ?? NSApp.keyWindow else { return false }
        let lower = Character(key.lowercased())
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers(for: key),
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           // As the keyboard reports it: "ignoring modifiers"
                                           // keeps ⇧, and the menu tells ⇧⌘T from ⌘T by it.
                                           characters: String(key), charactersIgnoringModifiers: String(key),
                                           isARepeat: false, keyCode: keyCodes[lower] ?? 0) else { return false }
        NSApp.sendEvent(event)
        return true
    }

    /// For an app that is not in front, where AppKit has no key window to
    /// send anything to: does by hand what the menu would do with the
    /// shortcut. The item is looked up by its key and modifiers, and its
    /// action is offered along `window`'s responder chain (first responder
    /// upward, the window and its controller, its delegate, the app, the
    /// app's delegate) to the first that implements it, unless that one
    /// refuses the item in validation. Says what happened.
    ///
    /// This checks the menu item and what it does, not the keyboard: no
    /// view is offered the key first, so it says nothing about a view that
    /// takes shortcuts for itself.
    static func performMenuItem(for key: Character, in window: NSWindow) -> String {
        let wanted = modifiers(for: key)
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
                if item.action != nil, item.keyEquivalent == key.lowercased(),
                   item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == wanted {
                    return item
                }
            }
            return nil
        }
        guard let item = NSApp.mainMenu.flatMap(find), let action = item.action else {
            return "no menu item has that shortcut"
        }
        var chain: [AnyObject] = []
        var responder = window.firstResponder
        while let current = responder {
            chain.append(current)
            responder = current.nextResponder
        }
        if !chain.contains(where: { $0 === window }) { chain.append(window) }
        if let delegate = window.delegate { chain.append(delegate) }
        chain.append(NSApp)
        if let delegate = NSApp.delegate { chain.append(delegate) }
        for candidate in chain where candidate.responds(to: action) {
            let refused = (candidate as? NSMenuItemValidation).map { !$0.validateMenuItem(item) }
                ?? (candidate as? NSUserInterfaceValidations).map { !$0.validateUserInterfaceItem(item) }
                ?? false
            if refused { return "“\(item.title)” is switched off by \(type(of: candidate))" }
            _ = candidate.perform(action, with: item)
            return "“\(item.title)” done by \(type(of: candidate))"
        }
        return "“\(item.title)”: nothing in the window takes it"
    }
}
