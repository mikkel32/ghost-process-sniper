import AppKit
import GhostProcessSniperCore
import SwiftUI

@MainActor
final class MenuBarCoordinator: NSObject, NSPopoverDelegate, NSMenuItemValidation {
    let monitor: ProcessMonitor

    private let killer: ProcessKiller
    private let notifier: UserNotificationRadarNotifier
    private let consoleController = RadarConsoleController()
    private let settingsController = SettingsWindowController()
    private let quickStops: QuickStopAdvisor
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var statusObserverID: UUID?
    private var quickStopObserverID: UUID?
    private var lastRenderedLevel: GhostLevel?
    private var lastRenderedPresentationKey = ""

    init(
        monitor: ProcessMonitor? = nil,
        killer: ProcessKiller = ProcessKiller()
    ) {
        let notifier = UserNotificationRadarNotifier()
        let monitor = monitor ?? ProcessMonitor(notifier: notifier)
        self.monitor = monitor
        self.killer = killer
        self.notifier = notifier
        quickStops = QuickStopAdvisor(monitor: monitor)
        super.init()
    }

    func start() {
        configureApplicationMenu()
        configureStatusItem()
        statusObserverID = monitor.addPublishedStateObserver { [weak self] state in
            self?.updateStatusIcon(state: state, force: false)
        }
        quickStopObserverID = monitor.addPublishedStateObserver { [weak self] _ in
            self?.quickStops.update()
        }
        monitor.start()
    }

    func openConsole() {
        consoleController.show(monitor: monitor, killer: killer, quickStops: quickStops) { [weak self] in
            self?.openSettings()
        }
    }

    /// Quick Stop from the popover or status menu: the console opens with
    /// the stop preview for the action's target, so every safety check and
    /// the confirmation still apply.
    func stopFamily(_ action: QuickStopAction) {
        popover?.close()
        monitor.setPopoverVisible(false)
        openConsole()
        consoleController.stopFamily(action)
    }

    func openSettings() {
        popover?.close()
        settingsController.show(monitor: monitor)
    }

    /// A notification click or action. Keys come from the notification, so the
    /// family is resolved again in case it restarted since the alert.
    func handleNotification(action: String, familyKey: String?, signatureID: String?) {
        let family = familyKey.flatMap { monitor.family(signatureID: $0) }
            ?? signatureID.flatMap { monitor.family(signatureID: $0) }
        switch action {
        case NotificationRouter.snoozeAction:
            guard let target = signatureID ?? familyKey else {
                return
            }
            Task { [monitor] in await monitor.snooze(signatureID: target, minutes: 60) }
        case NotificationRouter.stopAction:
            openConsole()
            if let family {
                consoleController.prepareKill(familyKey: family.familyKey)
            } else if let key = familyKey ?? signatureID {
                consoleController.focusFamily(key)
            }
        default:
            openConsole()
            if let key = family?.familyKey ?? familyKey ?? signatureID {
                consoleController.focusFamily(key)
            }
        }
    }

    func stop() {
        for id in [statusObserverID, quickStopObserverID].compactMap({ $0 }) {
            monitor.removePublishedStateObserver(id)
        }
        statusObserverID = nil
        quickStopObserverID = nil
        monitor.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        popover?.close()
        popover = nil
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let editItem = NSMenuItem()
        let radarItem = NSMenuItem()
        mainMenu.addItem(appItem)
        mainMenu.addItem(editItem)
        mainMenu.addItem(radarItem)

        let appMenu = NSMenu(title: "Ghost Process Sniper")
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Ghost Process Sniper",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        addMenuItem("Settings…", key: ",", modifiers: [.command], action: #selector(openSettingsCommand), to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ghost Process Sniper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Text fields only receive ⌘X/⌘C/⌘V/⌘A/⌘Z through these menu items;
        // without them the search field could not even paste a process name.
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let radarMenu = NSMenu(title: "Radar")
        radarItem.submenu = radarMenu
        addMenuItem("Open Console", key: "o", modifiers: [.command], action: #selector(openConsoleCommand), to: radarMenu)
        addMenuItem("Refresh Radar", key: "r", modifiers: [.command], action: #selector(refreshCommand), to: radarMenu)
        addMenuItem("Find", key: "f", modifiers: [.command], action: #selector(findCommand), to: radarMenu)
        addMenuItem("Next Family", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command], action: #selector(nextFamilyCommand), to: radarMenu)
        addMenuItem("Previous Family", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command], action: #selector(previousFamilyCommand), to: radarMenu)
        addMenuItem("Back", key: "[", modifiers: [.command], action: #selector(goBackCommand), to: radarMenu)
        addMenuItem("Forward", key: "]", modifiers: [.command], action: #selector(goForwardCommand), to: radarMenu)
        addMenuItem("Toggle Inspector", key: "i", modifiers: [.command, .option], action: #selector(toggleInspectorCommand), to: radarMenu)
        radarMenu.addItem(.separator())
        // Sidebar order.
        addMenuItem("Overview", key: "1", modifiers: [.command], action: #selector(showOverviewCommand), to: radarMenu)
        addMenuItem("All Processes", key: "2", modifiers: [.command], action: #selector(showProcessesCommand), to: radarMenu)
        addMenuItem("Duplicates", key: "3", modifiers: [.command], action: #selector(showDuplicatesCommand), to: radarMenu)
        addMenuItem("Incidents", key: "4", modifiers: [.command], action: #selector(showIncidentsCommand), to: radarMenu)
        addMenuItem("Rules", key: "5", modifiers: [.command], action: #selector(showRulesCommand), to: radarMenu)
        addMenuItem("Engine", key: "6", modifiers: [.command], action: #selector(showEngineCommand), to: radarMenu)
        radarMenu.addItem(.separator())
        addMenuItem("Copy Incident Report", key: "c", modifiers: [.command, .shift], action: #selector(copyReportCommand), to: radarMenu)
        addMenuItem("Copy Diagnostics", key: "d", modifiers: [.command, .shift], action: #selector(copyDiagnosticsCommand), to: radarMenu)
        addMenuItem("Snooze Family", key: "s", modifiers: [.command, .shift], action: #selector(snoozeCommand), to: radarMenu)
        addMenuItem("Ignore Family", key: "e", modifiers: [.command, .shift], action: #selector(ignoreCommand), to: radarMenu)
        addMenuItem("Stop…", key: String(UnicodeScalar(NSBackspaceCharacter)!), modifiers: [.command, .shift], action: #selector(killPreviewCommand), to: radarMenu)

        // The single menu definition: the SwiftUI scene declares no commands.
        NSApp.mainMenu = mainMenu
    }

    private func addMenuItem(
        _ title: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        action: Selector,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(refreshCommand), #selector(openConsoleCommand), #selector(openSettingsCommand), #selector(toggleInspectorCommand), #selector(copyReportCommand), #selector(copyDiagnosticsCommand), #selector(findCommand):
            return true
        case #selector(nextFamilyCommand), #selector(previousFamilyCommand):
            return monitor.commandAvailability(menuItem.action == #selector(nextFamilyCommand) ? .nextFamily : .previousFamily, selection: .overview).isEnabled
        case #selector(snoozeCommand), #selector(ignoreCommand):
            return consoleController.canActOnSelection(stop: false)
        case #selector(killPreviewCommand):
            return consoleController.canActOnSelection(stop: true)
        case #selector(goBackCommand):
            return consoleController.canGoBack
        case #selector(goForwardCommand):
            return consoleController.canGoForward
        default:
            return true
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior = [.removalAllowed, .terminationOnRemoval]
        item.autosaveName = NSStatusItem.AutosaveName("GhostProcessSniper.Radar")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.title = ""
        item.button?.setAccessibilityLabel("Ghost Process Sniper")
        statusItem = item
        updateStatusIcon(state: monitor.publishedState, force: true)
    }

    private func updateStatusIcon(state: ProcessMonitorPublishedState, force: Bool = true) {
        guard let button = statusItem?.button else {
            return
        }
        let presentation = MenuBarStatusPresentation(state: state)
        guard force || presentation.renderKey != lastRenderedPresentationKey else {
            return
        }
        lastRenderedPresentationKey = presentation.renderKey

        let started = Date()
        var didChange = false
        if lastRenderedLevel != presentation.level {
            button.image = StatusIconRenderer.image(level: presentation.level)
            lastRenderedLevel = presentation.level
            didChange = true
        }
        if button.toolTip != presentation.tooltip {
            button.toolTip = presentation.tooltip
            didChange = true
        }
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        if didChange {
            monitor.recordStatusUpdateCost(Date().timeIntervalSince(started) * 1_000)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else {
            return
        }

        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
            return
        }

        if let popover, popover.isShown {
            popover.close()
            button.highlight(false)
            monitor.setPopoverVisible(false)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: PopoverView(
                monitor: monitor,
                notifier: notifier,
                onOpenConsole: { [weak self] in
                    self?.popover?.close()
                    self?.monitor.setPopoverVisible(false)
                    self?.openConsole()
                },
                onOpenFamily: { [weak self] signatureID in
                    self?.popover?.close()
                    self?.monitor.setPopoverVisible(false)
                    self?.openConsole()
                    self?.consoleController.focusFamily(signatureID)
                },
                quickStops: quickStops,
                onStop: { [weak self] action in
                    self?.stopFamily(action)
                },
                onOpenSettings: { [weak self] in
                    self?.monitor.setPopoverVisible(false)
                    self?.openSettings()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        // The popover hugs its content; the triage list changes height.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        monitor.setPopoverVisible(true)
        RadarLogger.ui.info("Opened radar popover")
    }

    private func showStatusMenu() {
        guard let statusItem, let button = statusItem.button else {
            return
        }
        let menu = NSMenu()
        let presentation = MenuBarStatusPresentation(state: monitor.publishedState)
        let statusLine = NSMenuItem(title: presentation.tooltip, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let stopItems = quickStopMenuItems()
        if !stopItems.isEmpty {
            for item in stopItems {
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        addMenuItem("Open Console", key: "o", modifiers: [.command], action: #selector(openConsoleCommand), to: menu)
        addMenuItem("Refresh Radar", key: "r", modifiers: [.command], action: #selector(refreshCommand), to: menu)
        addMenuItem("Copy Diagnostics", key: "", modifiers: [], action: #selector(copyDiagnosticsQuietCommand), to: menu)
        menu.addItem(.separator())
        addMenuItem("Settings…", key: ",", modifiers: [.command], action: #selector(openSettingsCommand), to: menu)
        let quitItem = NSMenuItem(title: "Quit Ghost Process Sniper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// The riskiest culprits you can stop, straight from the right-click menu.
    private func quickStopMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for row in monitor.consoleSnapshot.compact.topRiskRows where items.count < 3 {
            guard let action = quickStops.actions[row.id], action.isAvailable else { continue }
            // "Quit TextEdit… — 1.2 GB", or "Stop Server… — vite, 1.2 GB" when the title has no name.
            var facts = action.title.contains(action.displayName) ? [] : [action.displayName]
            if let family = monitor.family(signatureID: action.familyKey) {
                facts.append(RadarFormat.bytes(family.totalPhysicalFootprintBytes))
            }
            let item = NSMenuItem(
                title: facts.isEmpty ? action.title : "\(action.title) — \(facts.joined(separator: ", "))",
                action: #selector(quickStopCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.familyKey
            item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
            item.toolTip = action.detail
            items.append(item)
        }
        return items
    }

    @objc private func quickStopCommand(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let action = quickStops.actions[key] else {
            return
        }
        stopFamily(action)
    }

    @objc private func goBackCommand() {
        openConsole()
        consoleController.goBack()
    }

    @objc private func goForwardCommand() {
        openConsole()
        consoleController.goForward()
    }

    @objc private func copyDiagnosticsQuietCommand() {
        Task { [monitor] in
            let report = await monitor.exportDiagnosticsReport()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    @objc private func showOverviewCommand() {
        openConsole()
        consoleController.focusSection(.overview)
    }

    @objc private func showProcessesCommand() {
        openConsole()
        consoleController.focusSection(.processes)
    }

    @objc private func showDuplicatesCommand() {
        openConsole()
        consoleController.focusSection(.duplicates)
    }

    @objc private func showIncidentsCommand() {
        openConsole()
        consoleController.focusSection(.incidents)
    }

    @objc private func showRulesCommand() {
        openConsole()
        consoleController.focusSection(.rules)
    }

    @objc private func showEngineCommand() {
        openConsole()
        consoleController.focusSection(.engine)
    }

    @objc private func openConsoleCommand() {
        openConsole()
    }

    @objc private func refreshCommand() {
        if !consoleController.refresh() {
            Task { await monitor.refresh() }
        }
    }

    @objc private func openSettingsCommand() {
        openSettings()
    }

    @objc private func findCommand() {
        openConsole()
        consoleController.find()
    }

    @objc private func nextFamilyCommand() {
        openConsole()
        consoleController.nextFamily()
    }

    @objc private func previousFamilyCommand() {
        openConsole()
        consoleController.previousFamily()
    }

    @objc private func toggleInspectorCommand() {
        openConsole()
        consoleController.toggleInspector()
    }

    @objc private func copyReportCommand() {
        openConsole()
        consoleController.copyReport()
    }

    @objc private func copyDiagnosticsCommand() {
        openConsole()
        consoleController.copyDiagnostics()
    }

    @objc private func snoozeCommand() {
        openConsole()
        consoleController.snoozeSelected()
    }

    @objc private func ignoreCommand() {
        openConsole()
        consoleController.ignoreSelected()
    }

    @objc private func killPreviewCommand() {
        openConsole()
        consoleController.prepareKillSelected()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        monitor.setPopoverVisible(false)
        RadarLogger.ui.info("Closed radar popover")
        popover = nil
    }
}
