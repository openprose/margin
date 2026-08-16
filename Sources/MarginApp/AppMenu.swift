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
                "Open…",
                action: #selector(AppDelegate.openDocument(_:)),
                key: "o",
                target: delegate
            )
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            item("Save", action: #selector(WorkspaceDocumentSaving.saveDocument(_:)), key: "s")
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close", action: #selector(NSWindow.performClose(_:)), key: "w"))
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
        mainMenu.addItem(menuItem(title: "Review", submenu: reviewMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
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
