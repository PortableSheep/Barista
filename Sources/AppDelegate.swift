import Cocoa
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var panel: NSPanel?
    private var panelModel: PanelModel?
    private var panelHostingController: NSViewController?
    private var panelGlobalEventMonitor: Any?
    private var panelLocalEventMonitor: Any?

    private var toggleItem: NSMenuItem!
    private var durationMenuItem: NSMenuItem!
    private var keepDisplayAwakeItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var updateAvailableItem: NSMenuItem!

    private let keepAwake = KeepAwakeManager()

    private var sessionEndDate: Date?
    private var countdownTimer: Timer?

    private var updateCheckTimer: Timer?
    private var latestReleaseURL: URL?
    private var latestReleaseTag: String?

    private let updateChecker = GitHubUpdateChecker(repoSlug: "PortableSheep/Barista")

    private var lastKnownActive = false

    private var isActive: Bool { keepAwake.isActive }

    private var durationSeconds: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: DefaultsKey.durationSeconds)
            return max(0, value)
        }
        set {
            UserDefaults.standard.set(max(0, newValue), forKey: DefaultsKey.durationSeconds)
        }
    }

    private var keepDisplayAwake: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.keepDisplayAwake) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.keepDisplayAwake) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = iconImage(active: false)
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Barista"

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildMenu()
        setupPanel()
        refreshMenuState()
        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopKeepAwakeIfNeeded()
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        guard let event = NSApp.currentEvent else {
            toggleKeepAwake()
            return
        }

        if event.type == .rightMouseUp {
            togglePanel(relativeTo: button)
            return
        }

        if event.type == .leftMouseUp {
            toggleKeepAwake()
        }
    }

    private func togglePanel(relativeTo button: NSStatusBarButton) {
        guard let panel else { return }

        if panel.isVisible {
            closePanel()
            return
        }

        panelModel?.refresh()

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = button.window?.convertToScreen(buttonRectInWindow) ?? .zero

        panelHostingController?.view.layoutSubtreeIfNeeded()
        let targetSize = panelHostingController?.view.fittingSize ?? NSSize(width: 300, height: 280)

        let width = max(280, min(360, targetSize.width))
        let height = max(240, min(520, targetSize.height))
        let gap: CGFloat = 2

        let x = buttonRectOnScreen.midX - (width / 2)
        let y = buttonRectOnScreen.minY - height - gap

        if let screen = button.window?.screen {
            var frame = NSRect(x: x, y: y, width: width, height: height)
            frame.origin.x = max(screen.visibleFrame.minX + 6, min(frame.origin.x, screen.visibleFrame.maxX - frame.size.width - 6))
            panel.setFrame(frame, display: false)
        } else {
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        }

        startPanelEventMonitors()
        panel.orderFrontRegardless()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        stopPanelEventMonitors()
    }

    private func startPanelEventMonitors() {
        stopPanelEventMonitors()

        panelGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let panel = self.panel, panel.isVisible else { return }
                let clickPoint = NSEvent.mouseLocation
                if !panel.frame.contains(clickPoint) {
                    self.closePanel()
                }
            }
        }

        panelLocalEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                Task { @MainActor in self.closePanel() }
                return nil
            }

            if let panel = self.panel, panel.isVisible {
                let clickPoint = NSEvent.mouseLocation
                if !panel.frame.contains(clickPoint) {
                    Task { @MainActor in self.closePanel() }
                    return event
                }
            }
            return event
        }
    }

    private func stopPanelEventMonitors() {
        if let monitor = panelGlobalEventMonitor {
            NSEvent.removeMonitor(monitor)
            panelGlobalEventMonitor = nil
        }
        if let monitor = panelLocalEventMonitor {
            NSEvent.removeMonitor(monitor)
            panelLocalEventMonitor = nil
        }
    }

    private func setupPanel() {
        let model = PanelModel()
        panelModel = model

        model.getSnapshot = { [weak self] in
            guard let self else {
                return .init(isActive: false, durationSeconds: 0, keepDisplayAwake: false, launchAtLoginEnabled: false, launchAtLoginOn: false, remainingLabel: nil, updateTitle: nil, hasUpdateURL: false)
            }

            let (launchEnabled, launchOn): (Bool, Bool)
            if #available(macOS 13.0, *) {
                launchEnabled = true
                launchOn = (SMAppService.mainApp.status == .enabled)
            } else {
                launchEnabled = false
                launchOn = false
            }

            return .init(
                isActive: self.isActive,
                durationSeconds: self.durationSeconds,
                keepDisplayAwake: self.keepDisplayAwake,
                launchAtLoginEnabled: launchEnabled,
                launchAtLoginOn: launchOn,
                remainingLabel: self.remainingLabelForPanel(),
                updateTitle: self.latestReleaseTag.map { "Update Available: \($0)" },
                hasUpdateURL: self.latestReleaseURL != nil
            )
        }

        model.setActive = { [weak self] active in
            guard let self else { return }
            if active != self.isActive {
                self.toggleKeepAwake()
            }
            self.refreshMenuState()
        }

        model.setDuration = { [weak self] seconds in
            self?.setDuration(seconds)
        }

        model.setKeepDisplayAwake = { [weak self] value in
            self?.setKeepDisplayAwake(value)
        }

        model.toggleLaunchAtLogin = { [weak self] in
            self?.toggleLaunchAtLogin()
        }

        model.openUpdate = { [weak self] in
            self?.openLatestRelease()
        }

        model.quit = { [weak self] in
            self?.quit()
        }

        let hosting = NSHostingController(rootView: PanelContentView(model: model))
        panelHostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentViewController = hosting

        self.panel = panel
    }

    private func buildMenu() {
        toggleItem = NSMenuItem(title: "Enable Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        durationMenuItem = NSMenuItem(title: "Duration", action: nil, keyEquivalent: "")
        durationMenuItem.submenu = buildDurationSubmenu()
        menu.addItem(durationMenuItem)

        keepDisplayAwakeItem = NSMenuItem(title: "Keep Display Awake", action: #selector(toggleKeepDisplayAwake), keyEquivalent: "")
        keepDisplayAwakeItem.target = self
        menu.addItem(keepDisplayAwakeItem)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        updateAvailableItem = NSMenuItem(title: "Update Available", action: #selector(openLatestRelease), keyEquivalent: "")
        updateAvailableItem.target = self
        updateAvailableItem.isHidden = true
        menu.addItem(updateAvailableItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func buildDurationSubmenu() -> NSMenu {
        let sub = NSMenu()

        sub.addItem(makeDurationItem(title: "Indefinitely", seconds: 0))
        sub.addItem(.separator())
        sub.addItem(makeDurationItem(title: "15 minutes", seconds: 15 * 60))
        sub.addItem(makeDurationItem(title: "30 minutes", seconds: 30 * 60))
        sub.addItem(makeDurationItem(title: "1 hour", seconds: 60 * 60))
        sub.addItem(makeDurationItem(title: "2 hours", seconds: 2 * 60 * 60))

        return sub
    }

    private func makeDurationItem(title: String, seconds: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectDuration(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = seconds
        return item
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        setDuration(seconds)
    }

    private func setDuration(_ seconds: Int) {
        durationSeconds = seconds

        if isActive {
            restartKeepAwake()
        } else {
            startKeepAwake()
        }

        refreshMenuState()
    }

    @objc private func toggleKeepDisplayAwake() {
        setKeepDisplayAwake(!keepDisplayAwake)
    }

    private func setKeepDisplayAwake(_ value: Bool) {
        keepDisplayAwake = value

        if isActive {
            restartKeepAwake()
        }

        refreshMenuState()
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                // keep UX minimal
            }
            refreshMenuState()
        } else {
            NSSound.beep()
        }
    }

    @objc private func toggleKeepAwake() {
        if isActive {
            stopKeepAwakeIfNeeded()
        } else {
            startKeepAwake()
        }
        refreshMenuState()
    }

    @objc private func openLatestRelease() {
        guard let url = latestReleaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startKeepAwake() {
        guard isActive == false else { return }

        keepAwake.start(keepDisplayAwake: keepDisplayAwake)

        if durationSeconds > 0 {
            sessionEndDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
        } else {
            sessionEndDate = nil
        }
    }

    private func stopKeepAwakeIfNeeded() {
        keepAwake.stop()
        stopCountdown()
    }

    private func restartKeepAwake() {
        stopKeepAwakeIfNeeded()
        startKeepAwake()
    }

    private func startCountdownIfNeeded() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        guard isActive, durationSeconds > 0, sessionEndDate != nil else {
            updateStatusItemTitle()
            return
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateStatusItemTitle()
            }
        }

        RunLoop.main.add(countdownTimer!, forMode: .common)
        updateStatusItemTitle()
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        sessionEndDate = nil
        updateStatusItemTitle()
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }

        guard isActive, durationSeconds > 0, let endDate = sessionEndDate else {
            button.title = ""
            return
        }

        let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        if remaining == 0 {
            stopKeepAwakeIfNeeded()
            refreshMenuState()
            return
        }

        button.title = formatRemainingTime(seconds: remaining)
    }

    private func remainingLabelForPanel() -> String? {
        guard isActive, durationSeconds > 0, let endDate = sessionEndDate else { return nil }
        let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        if remaining == 0 { return nil }
        return formatRemainingTime(seconds: remaining)
    }

    private func formatRemainingTime(seconds: Int) -> String {
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = Int(ceil(Double(seconds % 3600) / 60.0))
            if minutes == 0 { return "\(hours)h" }
            return "\(hours)h\(minutes)m"
        }

        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        return "\(minutes)m"
    }

    private func refreshMenuState() {
        let active = isActive
        statusItem.button?.image = iconImage(active: active)
        startCountdownIfNeeded()

        panelModel?.refresh()

        toggleItem.title = active ? "Disable Keep Awake" : "Enable Keep Awake"
        keepDisplayAwakeItem.state = keepDisplayAwake ? .on : .off

        if #available(macOS 13.0, *) {
            launchAtLoginItem.isEnabled = true
            launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } else {
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.state = .off
        }

        if let durationMenu = durationMenuItem.submenu {
            for item in durationMenu.items {
                guard let seconds = item.representedObject as? Int else { continue }
                item.state = (seconds == durationSeconds) ? .on : .off
            }
        }

        updateAvailableItem.isHidden = (latestReleaseURL == nil || latestReleaseTag == nil)
        if let tag = latestReleaseTag {
            updateAvailableItem.title = "Update Available: \(tag)"
        }

        let tooltipSuffix: String
        if !active {
            tooltipSuffix = "Off"
        } else if durationSeconds > 0 {
            tooltipSuffix = "On (timed)"
        } else {
            tooltipSuffix = "On"
        }
        statusItem.button?.toolTip = "Barista — \(tooltipSuffix)\nClick: Toggle  •  Right-click: Options"

        if active != lastKnownActive {
            animateStateTransition(toActive: active)
            lastKnownActive = active
        }
    }

    private func animateStateTransition(toActive: Bool) {
        guard let button = statusItem.button else { return }

        button.alphaValue = 1.0

        let dipAlpha: CGFloat = toActive ? 0.55 : 0.75
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            button.animator().alphaValue = dipAlpha
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.allowsImplicitAnimation = true
                button.animator().alphaValue = 1.0
            }
        }
    }

    private func iconImage(active: Bool) -> NSImage? {
        let name = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Barista")
        image?.isTemplate = true
        return image
    }

    private func scheduleUpdateChecks() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil

        Task { @MainActor in
            await checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkForUpdates()
            }
        }
        RunLoop.main.add(updateCheckTimer!, forMode: .common)
    }

    private func currentAppVersion() -> String {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String
        let bundle = dict?["CFBundleVersion"] as? String
        return (short?.isEmpty == false ? short! : (bundle ?? "0.0.0"))
    }

    private func checkForUpdates() async {
        let current = currentAppVersion()
        if let info = await updateChecker.check(currentVersion: current) {
            latestReleaseTag = info.tag
            latestReleaseURL = info.url
        } else {
            latestReleaseTag = nil
            latestReleaseURL = nil
        }
        refreshMenuState()
    }
}
