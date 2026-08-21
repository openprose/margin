import AppKit

enum AppMenu {
    static func install(for application: NSApplication, delegate: AppDelegate) {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationMenu = NSMenu(title: "Margin")
        applicationMenu.addItem(
            item(
                "About Margin",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                target: application
            )
        )
        applicationMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        application.servicesMenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            item(
                "Hide Margin",
                action: #selector(NSApplication.hide(_:)),
                key: "h",
                target: application
            )
        )
        applicationMenu.addItem(
            item(
                "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                key: "h",
                modifiers: [.command, .option],
                target: application
            )
        )
        applicationMenu.addItem(
            item(
                "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                target: application
            )
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            item(
                "Quit Margin",
                action: #selector(NSApplication.terminate(_:)),
                key: "q",
                target: application
            )
        )
        mainMenu.addItem(menuItem(title: "Margin", submenu: applicationMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            item(
                "New Tab",
                action: #selector(AppDelegate.newWindowForTab(_:)),
                key: "t",
                target: delegate
            )
        )
        fileMenu.addItem(
            item(
                "New Window",
                action: #selector(AppDelegate.newWindow(_:)),
                key: "n",
                target: delegate
            )
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            item(
                "Open…",
                action: #selector(AppDelegate.openDocument(_:)),
                key: "o",
                target: delegate
            )
        )
        fileMenu.addItem(
            item(
                "Quick Open…",
                action: #selector(AppDelegate.quickOpen(_:)),
                key: "p",
                target: delegate
            )
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            item(
                "Rename Navigator Item…",
                action: Selector(("renameNavigatorItem:"))
            )
        )
        fileMenu.addItem(
            item(
                "Copy Path",
                action: Selector(("copyNavigatorPath:")),
                key: "c",
                modifiers: [.command, .option, .shift]
            )
        )
        fileMenu.addItem(
            item(
                "Copy Full Path",
                action: Selector(("copyNavigatorFullPath:")),
                key: "c",
                modifiers: [.command, .option]
            )
        )
        fileMenu.addItem(
            item(
                "Reveal in Finder",
                action: Selector(("revealNavigatorItemInFinder:")),
                key: "r",
                modifiers: [.command, .option]
            )
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            item("Save", action: #selector(WorkspaceDocumentSaving.saveDocument(_:)), key: "s")
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close Tab", action: #selector(NSWindow.performClose(_:)), key: "w"))
        mainMenu.addItem(menuItem(title: "File", submenu: fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(
            item(
                "Redo",
                action: Selector(("redo:")),
                key: "z",
                modifiers: [.command, .shift]
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(
            item(
                "Paste and Match Style",
                action: #selector(NSTextView.pasteAsPlainText(_:)),
                key: "v",
                modifiers: [.command, .option, .shift]
            )
        )
        editMenu.addItem(item("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Bold", action: Selector(("toggleBold:")), key: "b"))
        editMenu.addItem(item("Italic", action: Selector(("toggleItalic:")), key: "i"))
        editMenu.addItem(item("Link", action: Selector(("insertLink:")), key: "k"))
        editMenu.addItem(.separator())

        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(findItem("Find…", tag: 1, key: "f"))
        findMenu.addItem(findItem("Find Next", tag: 2, key: "g"))
        findMenu.addItem(
            findItem("Find Previous", tag: 3, key: "g", modifiers: [.command, .shift])
        )
        findMenu.addItem(findItem("Use Selection for Find", tag: 7, key: "e"))
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findMenu
        editMenu.addItem(findItem)
        mainMenu.addItem(menuItem(title: "Edit", submenu: editMenu))

        let navigateMenu = NSMenu(title: "Navigate")
        navigateMenu.addItem(
            item(
                "Command Palette…",
                action: #selector(AppDelegate.showCommandPalette(_:)),
                key: "p",
                modifiers: [.command, .shift],
                target: delegate
            )
        )
        navigateMenu.addItem(.separator())
        navigateMenu.addItem(
            item(
                "Go to Heading…",
                action: #selector(AppDelegate.navigateToHeading(_:)),
                key: "o",
                modifiers: [.command, .shift],
                target: delegate
            )
        )
        navigateMenu.addItem(.separator())
        navigateMenu.addItem(
            item(
                "Previous File",
                action: #selector(AppDelegate.previousFile(_:)),
                key: "\u{F702}",
                modifiers: [.command, .option],
                target: delegate
            )
        )
        navigateMenu.addItem(
            item(
                "Next File",
                action: #selector(AppDelegate.nextFile(_:)),
                key: "\u{F703}",
                modifiers: [.command, .option],
                target: delegate
            )
        )
        navigateMenu.addItem(.separator())
        navigateMenu.addItem(
            item(
                "Focus Navigator",
                action: #selector(AppDelegate.focusNavigator(_:)),
                key: "1",
                modifiers: [.control],
                target: delegate
            )
        )
        navigateMenu.addItem(
            item(
                "Focus Editor",
                action: #selector(AppDelegate.focusEditor(_:)),
                key: "2",
                modifiers: [.control],
                target: delegate
            )
        )
        navigateMenu.addItem(
            item(
                "Focus Comments",
                action: #selector(AppDelegate.focusComments(_:)),
                key: "3",
                modifiers: [.control],
                target: delegate
            )
        )
        mainMenu.addItem(menuItem(title: "Navigate", submenu: navigateMenu))

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            item(
                "Show Navigator",
                action: #selector(AppDelegate.toggleNavigator(_:)),
                key: "0",
                target: delegate
            )
        )
        viewMenu.addItem(
            item(
                "Show Comments",
                action: #selector(AppDelegate.toggleComments(_:)),
                key: "0",
                modifiers: [.command, .option],
                target: delegate
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            item(
                "Reader Mode",
                action: #selector(AppDelegate.toggleReaderMode(_:)),
                key: "r",
                modifiers: [.command, .shift],
                target: delegate
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            item(
                "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                key: "f",
                modifiers: [.command, .control]
            )
        )
        mainMenu.addItem(menuItem(title: "View", submenu: viewMenu))

        let reviewMenu = NSMenu(title: "Review")
        reviewMenu.addItem(
            item(
                "Add Comment",
                action: Selector(("beginComment:")),
                key: "m",
                modifiers: [.command, .option]
            )
        )
        reviewMenu.addItem(
            item(
                "Show Comments",
                action: #selector(AppDelegate.toggleComments(_:)),
                key: "c",
                modifiers: [.command, .control],
                target: delegate
            )
        )
        reviewMenu.addItem(
            item(
                "Go to Comment…",
                action: #selector(AppDelegate.navigateToComment(_:)),
                target: delegate
            )
        )
        reviewMenu.addItem(.separator())
        reviewMenu.addItem(
            item(
                "Previous Open Comment",
                action: #selector(AppDelegate.previousOpenComment(_:)),
                key: "[",
                modifiers: [.command, .option],
                target: delegate
            )
        )
        reviewMenu.addItem(
            item(
                "Next Open Comment",
                action: #selector(AppDelegate.nextOpenComment(_:)),
                key: "]",
                modifiers: [.command, .option],
                target: delegate
            )
        )
        reviewMenu.addItem(
            item(
                "Resolve Current Comment",
                action: #selector(AppDelegate.resolveCurrentComment(_:)),
                target: delegate
            )
        )
        mainMenu.addItem(menuItem(title: "Review", submenu: reviewMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            item(
                "Show Previous Tab",
                action: #selector(NSWindow.selectPreviousTab(_:)),
                key: "\t",
                modifiers: [.control, .shift]
            )
        )
        windowMenu.addItem(
            item(
                "Show Next Tab",
                action: #selector(NSWindow.selectNextTab(_:)),
                key: "\t",
                modifiers: [.control]
            )
        )
        let previousTabAlternate = item(
            "Previous Tab",
            action: #selector(NSWindow.selectPreviousTab(_:)),
            key: "[",
            modifiers: [.command, .shift]
        )
        previousTabAlternate.isHidden = true
        previousTabAlternate.allowsKeyEquivalentWhenHidden = true
        windowMenu.addItem(previousTabAlternate)
        let nextTabAlternate = item(
            "Next Tab",
            action: #selector(NSWindow.selectNextTab(_:)),
            key: "]",
            modifiers: [.command, .shift]
        )
        nextTabAlternate.isHidden = true
        nextTabAlternate.allowsKeyEquivalentWhenHidden = true
        windowMenu.addItem(nextTabAlternate)

        let selectTabMenu = NSMenu(title: "Select Tab")
        for index in 1...9 {
            let title = index == 9 ? "Last Tab" : "Tab \(index)"
            let tabItem = item(
                title,
                action: #selector(AppDelegate.selectTab(_:)),
                key: String(index),
                target: delegate
            )
            tabItem.tag = index
            selectTabMenu.addItem(tabItem)
        }
        windowMenu.addItem(menuItem(title: "Select Tab", submenu: selectTabMenu))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:))))
        windowMenu.addItem(item("Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:))))
        windowMenu.addItem(
            item(
                "Show All Tabs",
                action: #selector(NSWindow.toggleTabOverview(_:)),
                key: "\\",
                modifiers: [.command, .shift]
            )
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            item(
                "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                target: application
            )
        )
        application.windowsMenu = windowMenu
        mainMenu.addItem(menuItem(title: "Window", submenu: windowMenu))

        application.mainMenu = mainMenu
    }

    private static func menuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }

    private static func item(
        _ title: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menuItem.target = target
        return menuItem
    }

    private static func findItem(
        _ title: String,
        tag: Int,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let menuItem = item(
            title,
            action: #selector(NSTextView.performTextFinderAction(_:)),
            key: key,
            modifiers: modifiers
        )
        menuItem.tag = tag
        return menuItem
    }
}
