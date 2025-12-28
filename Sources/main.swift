import Cocoa
import ServiceManagement

private enum DefaultsKey {
    static let durationSeconds = "durationSeconds"
    static let keepDisplayAwake = "keepDisplayAwake"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var toggleItem: NSMenuItem!
    private var durationMenuItem: NSMenuItem!
    private var keepDisplayAwakeItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private var caffeinateProcess: Process?

    private var sessionEndDate: Date?
    private var countdownTimer: Timer?

    private var lastKnownActive = false

    private var isActive: Bool {
        caffeinateProcess?.isRunning == true
    }

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
        get {
            UserDefaults.standard.object(forKey: DefaultsKey.keepDisplayAwake) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.keepDisplayAwake)
        }
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
        refreshMenuState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCaffeinateIfNeeded()
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

        // Keep ticking during menu tracking modes.
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
            // If caffeinate hasn't terminated yet, avoid showing stale time.
            button.title = ""
            return
        }

        button.title = formatRemainingTime(seconds: remaining)
    }

    private func formatRemainingTime(seconds: Int) -> String {
        // Display a compact, rounded-up label (e.g. 15m, 2h5m).
        // For sub-hour values we round up to the next minute so 14:59 shows as 15m.
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = Int(ceil(Double(seconds % 3600) / 60.0))
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h\(minutes)m"
        }

        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        return "\(minutes)m"
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

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        guard let event = NSApp.currentEvent else {
            toggleKeepAwake()
            return
        }

        let isContextClick = (event.type == .rightMouseUp) || event.modifierFlags.contains(.control)
        if isContextClick {
            refreshMenuState()
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            toggleKeepAwake()
        }
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
        durationSeconds = seconds

        // Selecting a duration implies enabling keep-awake with that duration.
        if isActive {
            restartCaffeinate()
        } else {
            startCaffeinate()
            refreshMenuState()
        }
    }

    @objc private func toggleKeepDisplayAwake() {
        keepDisplayAwake.toggle()

        if isActive {
            restartCaffeinate()
        } else {
            refreshMenuState()
        }
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
                // Intentionally silent: keep UX minimal.
            }
            refreshMenuState()
        } else {
            NSSound.beep()
        }
    }

    @objc private func toggleKeepAwake() {
        if isActive {
            stopCaffeinateIfNeeded()
        } else {
            startCaffeinate()
        }
        refreshMenuState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func restartCaffeinate() {
        stopCaffeinateIfNeeded()
        startCaffeinate()
        refreshMenuState()
    }

    private func startCaffeinate() {
        guard caffeinateProcess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

        var args: [String] = ["-i"]
        if keepDisplayAwake {
            args.append("-d")
        }
        if durationSeconds > 0 {
            args.append(contentsOf: ["-t", String(durationSeconds)])
        }
        process.arguments = args

        process.standardOutput = nil
        process.standardError = nil

        // Important: avoid a race where an older process' termination handler fires
        // after we already started a new one (during restart). Only clear if it's
        // still the active tracked process.
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let terminated = process else { return }
                if self.caffeinateProcess === terminated {
                    self.caffeinateProcess = nil
                    self.stopCountdown()
                    self.refreshMenuState()
                }
            }
        }

        do {
            try process.run()
            caffeinateProcess = process

            if durationSeconds > 0 {
                sessionEndDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
            } else {
                sessionEndDate = nil
            }
        } catch {
            caffeinateProcess = nil
            sessionEndDate = nil
        }
    }

    private func stopCaffeinateIfNeeded() {
        guard let process = caffeinateProcess else { return }
        if process.isRunning {
            process.terminate()
        }
        caffeinateProcess = nil
        stopCountdown()
    }

    private func refreshMenuState() {
        let active = isActive
        statusItem.button?.image = iconImage(active: active)
        startCountdownIfNeeded()

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
}

@main
struct BaristaApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
