import Cocoa
import IOKit.pwr_mgt
import ServiceManagement
import SwiftUI

private enum DefaultsKey {
    static let durationSeconds = "durationSeconds"
    static let keepDisplayAwake = "keepDisplayAwake"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var panel: NSPanel?
    private var panelModel: PopoverModel?
    private var panelHostingController: NSViewController?
    private var panelGlobalEventMonitor: Any?
    private var panelLocalEventMonitor: Any?

    private var toggleItem: NSMenuItem!
    private var durationMenuItem: NSMenuItem!
    private var keepDisplayAwakeItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var updateAvailableItem: NSMenuItem!

    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var displaySleepAssertionID: IOPMAssertionID = 0

    private var sessionEndDate: Date?
    private var countdownTimer: Timer?

    private var updateCheckTimer: Timer?
    private var latestReleaseURL: URL?
    private var isCheckingForUpdates = false

    private var lastKnownActive = false

    private var isActive: Bool {
        systemSleepAssertionID != 0
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

        setupPanel()

        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopKeepAwakeIfNeeded()
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
            // Time is up.
            stopKeepAwakeIfNeeded()
            refreshMenuState()
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

        updateAvailableItem = NSMenuItem(title: "Update Available", action: #selector(openLatestRelease), keyEquivalent: "")
        updateAvailableItem.target = self
        updateAvailableItem.isHidden = true
        menu.addItem(updateAvailableItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func setupPanel() {
        let model = PopoverModel(app: self)
        panelModel = model

        let hosting = NSHostingController(rootView: PopoverContentView(model: model))
        panelHostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 280),
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

        // SwiftUI view is responsible for its own material background.
        panel.contentViewController = hosting

        self.panel = panel
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
            if event.type == .keyDown, event.keyCode == 53 { // Escape
                Task { @MainActor in self.closePanel() }
                return nil
            }

            // If click is outside panel, close.
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

    private func closePanel() {
        panel?.orderOut(nil)
        stopPanelEventMonitors()
    }

    private func scheduleUpdateChecks() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil

        // Initial check shortly after launch.
        Task { @MainActor in
            await checkForUpdates()
        }

        // Periodic checks (keep it infrequent to avoid rate limits).
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkForUpdates()
            }
        }
        RunLoop.main.add(updateCheckTimer!, forMode: .common)
    }

    private struct GitHubLatestRelease: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
    }

    private func currentAppVersion() -> String {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String
        let bundle = dict?["CFBundleVersion"] as? String
        return (short?.isEmpty == false ? short! : (bundle ?? "0.0.0"))
    }

    private func normalizedVersion(_ version: String) -> [Int] {
        // Strip leading 'v' and keep numeric dot-separated components.
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "v", with: "", options: [.anchored])

        return cleaned
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let va = normalizedVersion(a)
        let vb = normalizedVersion(b)
        let n = max(va.count, vb.count)
        for i in 0..<n {
            let ai = i < va.count ? va[i] : 0
            let bi = i < vb.count ? vb[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    private func setUpdateAvailable(tag: String?, url: URL?) {
        latestReleaseURL = url

        if let tag, let _ = url {
            updateAvailableItem.title = "Update Available: \(tag)"
            updateAvailableItem.isEnabled = true
            updateAvailableItem.isHidden = false
        } else {
            updateAvailableItem.isHidden = true
        }
    }

    private func githubRepoSlug() -> String {
        // Keep in sync with scripts/install.sh default.
        return "PortableSheep/Barista"
    }

    private func makeGitHubRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Barista", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let apiURL = URL(string: "https://api.github.com/repos/\(githubRepoSlug())/releases/latest")!
        do {
            let (data, _) = try await URLSession.shared.data(for: makeGitHubRequest(url: apiURL))
            let latest = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)

            // Ignore drafts/prereleases.
            if latest.draft == true || latest.prerelease == true {
                setUpdateAvailable(tag: nil, url: nil)
                return
            }

            let current = currentAppVersion()
            let latestTag = latest.tag_name
            let latestURL = URL(string: latest.html_url)

            if isVersion(latestTag, newerThan: current) {
                setUpdateAvailable(tag: latestTag, url: latestURL)
            } else {
                setUpdateAvailable(tag: nil, url: nil)
            }
        } catch {
            // Fail silently; don't show stale update UI.
            setUpdateAvailable(tag: nil, url: nil)
        }
    }

    @objc private func openLatestRelease() {
        guard let url = latestReleaseURL else { return }
        NSWorkspace.shared.open(url)
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

        panelModel?.refreshFromApp()

        // Determine the status item button frame in screen coordinates.
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = button.window?.convertToScreen(buttonRectInWindow) ?? .zero

        // Ensure hosting view has laid out its preferred size.
        panelHostingController?.view.layoutSubtreeIfNeeded()
        let targetSize = panelHostingController?.view.fittingSize ?? NSSize(width: 280, height: 260)

        let width = max(260, min(340, targetSize.width))
        let height = max(240, min(420, targetSize.height))
        let gap: CGFloat = 2

        let x = buttonRectOnScreen.midX - (width / 2)
        let y = buttonRectOnScreen.minY - height - gap

        if let screen = button.window?.screen {
            var frame = NSRect(x: x, y: y, width: width, height: height)
            frame = frame.offsetBy(dx: 0, dy: 0)
            // Clamp horizontally so it doesn't go off-screen.
            frame.origin.x = max(screen.visibleFrame.minX + 6, min(frame.origin.x, screen.visibleFrame.maxX - frame.size.width - 6))
            panel.setFrame(frame, display: false)
        } else {
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        }

        startPanelEventMonitors()
        panel.orderFrontRegardless()
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
            restartKeepAwake()
        } else {
            startKeepAwake()
            refreshMenuState()
        }
    }

    @objc private func toggleKeepDisplayAwake() {
        keepDisplayAwake.toggle()

        if isActive {
            restartKeepAwake()
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
            stopKeepAwakeIfNeeded()
        } else {
            startKeepAwake()
        }
        refreshMenuState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func restartKeepAwake() {
        stopKeepAwakeIfNeeded()
        startKeepAwake()
        refreshMenuState()
    }

    private func startKeepAwake() {
        guard systemSleepAssertionID == 0 else { return }

        let reason = "Barista Keep Awake" as CFString

        var systemID: IOPMAssertionID = 0
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemID
        )
        guard systemResult == kIOReturnSuccess else {
            systemSleepAssertionID = 0
            return
        }
        systemSleepAssertionID = systemID

        if keepDisplayAwake {
            var displayID: IOPMAssertionID = 0
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &displayID
            )
            if displayResult == kIOReturnSuccess {
                displaySleepAssertionID = displayID
            } else {
                displaySleepAssertionID = 0
            }
        } else {
            displaySleepAssertionID = 0
        }

        if durationSeconds > 0 {
            sessionEndDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
        } else {
            sessionEndDate = nil
        }
    }

    private func stopKeepAwakeIfNeeded() {
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }
        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }
        stopCountdown()
    }

    private func refreshMenuState() {
        let active = isActive
        statusItem.button?.image = iconImage(active: active)
        startCountdownIfNeeded()

        panelModel?.refreshFromApp()

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

    private func remainingLabelForPopover() -> String? {
        guard isActive, durationSeconds > 0, let endDate = sessionEndDate else { return nil }
        let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        if remaining == 0 { return nil }
        return formatRemainingTime(seconds: remaining)
    }

    private func setDurationFromPopover(seconds: Int) {
        durationSeconds = seconds
        if isActive {
            restartKeepAwake()
        } else {
            startKeepAwake()
        }
        refreshMenuState()
    }

    @MainActor
    private final class PopoverModel: ObservableObject {
        private weak var app: AppDelegate?

        @Published var isActive: Bool = false
        @Published var durationSeconds: Int = 0
        @Published var keepDisplayAwake: Bool = false
        @Published var launchAtLoginEnabled: Bool = false
        @Published var launchAtLoginOn: Bool = false
        @Published var remainingLabel: String? = nil
        @Published var updateTitle: String? = nil
        @Published var hasUpdateURL: Bool = false

        init(app: AppDelegate) {
            self.app = app
            refreshFromApp()
        }

        func refreshFromApp() {
            guard let app else { return }
            isActive = app.isActive
            durationSeconds = app.durationSeconds
            keepDisplayAwake = app.keepDisplayAwake
            remainingLabel = app.remainingLabelForPopover()
            updateTitle = app.updateAvailableItem.isHidden ? nil : app.updateAvailableItem.title
            hasUpdateURL = app.latestReleaseURL != nil

            if #available(macOS 13.0, *) {
                launchAtLoginEnabled = true
                launchAtLoginOn = (SMAppService.mainApp.status == .enabled)
            } else {
                launchAtLoginEnabled = false
                launchAtLoginOn = false
            }
        }

        func toggleActive() {
            app?.toggleKeepAwake()
            refreshFromApp()
        }

        func setActive(_ value: Bool) {
            guard let app else { return }
            if value != app.isActive {
                app.toggleKeepAwake()
            }
            refreshFromApp()
        }

        func setDuration(_ seconds: Int) {
            app?.setDurationFromPopover(seconds: seconds)
            refreshFromApp()
        }

        func setKeepDisplayAwake(_ value: Bool) {
            guard let app else { return }
            app.keepDisplayAwake = value
            if app.isActive {
                app.restartKeepAwake()
            }
            app.refreshMenuState()
            refreshFromApp()
        }

        func toggleLaunchAtLogin() {
            app?.toggleLaunchAtLogin()
            refreshFromApp()
        }

        func openUpdate() {
            app?.openLatestRelease()
        }

        func quit() {
            app?.quit()
        }
    }

    private struct PopoverContentView: View {
        @ObservedObject var model: PopoverModel

        private let durations: [(label: String, seconds: Int)] = [
            ("∞", 0),
            ("15m", 15 * 60),
            ("30m", 30 * 60),
            ("1h", 60 * 60),
            ("2h", 2 * 60 * 60)
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(model.isActive ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                        .frame(width: 8, height: 8)
                        .scaleEffect(model.isActive ? 1.0 : 0.85)
                        .opacity(model.isActive ? 1.0 : 0.55)
                        .animation(.easeInOut(duration: 0.18), value: model.isActive)

                    Label("Barista", systemImage: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.bounce, value: model.isActive)

                    Spacer()

                    if model.isActive, let remaining = model.remainingLabel {
                        Text(remaining)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("", isOn: Binding(
                        get: { model.isActive },
                        set: { model.setActive($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(PillToggleStyle(onColor: .green))
                }

                Picker("Duration", selection: Binding(
                    get: { model.durationSeconds },
                    set: { model.setDuration($0) }
                )) {
                    ForEach(durations, id: \.seconds) { item in
                        Text(item.label).tag(item.seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Toggle("Keep Display Awake", isOn: Binding(
                    get: { model.keepDisplayAwake },
                    set: { model.setKeepDisplayAwake($0) }
                ))

                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLoginOn },
                    set: { _ in model.toggleLaunchAtLogin() }
                ))
                .disabled(!model.launchAtLoginEnabled)

                if let updateTitle = model.updateTitle, model.hasUpdateURL {
                    Button(updateTitle) {
                        model.openUpdate()
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Quit") {
                        model.quit()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .tint(model.isActive ? .green : .accentColor)
        }
    }

    private struct PillToggleStyle: ToggleStyle {
        var onColor: Color = .green

        func makeBody(configuration: Configuration) -> some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(onColor.gradient) : AnyShapeStyle(.quaternary))

                    Circle()
                        .fill(.background)
                        .shadow(radius: 1, y: 1)
                        .padding(2)
                }
                .frame(width: 42, height: 24)
                .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Keep Awake"))
            .accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
        }
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
