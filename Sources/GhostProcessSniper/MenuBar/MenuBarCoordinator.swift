import AppKit
import GhostProcessSniperCore
import SwiftUI

@MainActor
final class MenuBarCoordinator: NSObject, NSPopoverDelegate, NSMenuItemValidation {
    let monitor: ProcessMonitor

    private let killer: ProcessKiller
    private let notifier: UserNotificationRadarNotifier
    private let consoleController = RadarConsoleController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var statusObserverID: UUID?
    private var lastRenderedLevel: GhostLevel?
    private var lastRenderedPresentationKey = ""

    init(
        monitor: ProcessMonitor? = nil,
        killer: ProcessKiller = ProcessKiller()
    ) {
        let notifier = UserNotificationRadarNotifier()
        self.monitor = monitor ?? ProcessMonitor(notifier: notifier)
        self.killer = killer
        self.notifier = notifier
        super.init()
    }

    func start() {
        configureApplicationMenu()
        configureStatusItem()
        statusObserverID = monitor.addPublishedStateObserver { [weak self] state in
            self?.updateStatusIcon(state: state, force: false)
        }
        monitor.start()
    }

    func openConsole() {
        consoleController.show(monitor: monitor, killer: killer)
    }

    func openSection(_ selection: RadarFocusedSelection) {
        openConsole()
        consoleController.focusSection(selection)
    }

    func findProcesses() {
        openConsole()
        consoleController.find()
    }

    func stop() {
        if let statusObserverID {
            monitor.removePublishedStateObserver(statusObserverID)
        }
        statusObserverID = nil
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
        addMenuItem("Toggle Inspector", key: "i", modifiers: [.command, .option], action: #selector(toggleInspectorCommand), to: radarMenu)
        radarMenu.addItem(.separator())
        addMenuItem("Overview", key: "1", modifiers: [.command], action: #selector(showOverviewCommand), to: radarMenu)
        addMenuItem("All Processes", key: "2", modifiers: [.command], action: #selector(showProcessesCommand), to: radarMenu)
        addMenuItem("Duplicates", key: "3", modifiers: [.command], action: #selector(showDuplicatesCommand), to: radarMenu)
        addMenuItem("Incidents", key: "4", modifiers: [.command], action: #selector(showIncidentsCommand), to: radarMenu)
        addMenuItem("Rules", key: "5", modifiers: [.command], action: #selector(showRulesCommand), to: radarMenu)
        radarMenu.addItem(.separator())
        addMenuItem("Copy Incident Report", key: "c", modifiers: [.command, .shift], action: #selector(copyReportCommand), to: radarMenu)
        addMenuItem("Copy Diagnostics", key: "d", modifiers: [.command, .shift], action: #selector(copyDiagnosticsCommand), to: radarMenu)
        addMenuItem("Snooze Family", key: "s", modifiers: [.command, .shift], action: #selector(snoozeCommand), to: radarMenu)
        addMenuItem("Ignore Family", key: "e", modifiers: [.command, .shift], action: #selector(ignoreCommand), to: radarMenu)
        addMenuItem("Kill Preview", key: "k", modifiers: [.command, .shift], action: #selector(killPreviewCommand), to: radarMenu)

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
        case #selector(snoozeCommand), #selector(ignoreCommand), #selector(killPreviewCommand):
            return true
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
        if button.title != presentation.title {
            button.title = presentation.title
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

        if NSApp.currentEvent?.type == .rightMouseUp {
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
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
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
                onQuit: { NSApp.terminate(nil) }
            )
        )

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
        addMenuItem("Open Console", key: "o", modifiers: [.command], action: #selector(openConsoleCommand), to: menu)
        addMenuItem("Refresh Radar", key: "r", modifiers: [.command], action: #selector(refreshCommand), to: menu)
        addMenuItem("Copy Diagnostics", key: "", modifiers: [], action: #selector(copyDiagnosticsQuietCommand), to: menu)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Ghost Process Sniper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
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

    @objc private func openConsoleCommand() {
        openConsole()
    }

    @objc private func refreshCommand() {
        if !consoleController.refresh() {
            Task { await monitor.refresh() }
        }
    }

    @objc private func openSettingsCommand() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
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
