import AppKit

/// HerdrBar — a macOS menu bar companion for herdr.
///
/// Left click brings the terminal running herdr to the front. Right click opens
/// a menu for starting herdr in a folder, jumping to a recent project, and
/// seeing which agent is waiting for input.
///
/// Note on notifications: herdr already delivers its own (`[ui.toast]`,
/// `[ui.sound]`). This app posts none and changes none of that configuration —
/// it only makes an existing "agent is waiting" state easy to spot by animating
/// the menu bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var icon: IconController!
    private let panel = AgentsPanel()
    private let events = EventServer()
    private let agents = AgentWatch()
    private var config = Config.load()

    /// Panes whose waiting state the user has already seen. A pane that starts
    /// waiting later is absent here, so the icon flashes again for it.
    private var acknowledged = Set<String>()

    /// Cached for menu building; refreshed just before the menu opens.
    private var snapshot: Snapshot?
    private var serverRunning = false

    /// Stops the blink once `config.blinkTimeoutSeconds` has elapsed, so an
    /// agent left waiting overnight does not blink forever.
    private var blinkDeadline: Timer?
    private var wasFlashing = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One icon only. A second copy finds the socket already owned and exits
        // rather than stacking a duplicate in the menu bar.
        guard events.start() else {
            NSApp.terminate(nil)
            return
        }

        Paths.ensureSupportDir()
        config.save()

        // IconController owns the length from here on: it grows the item when
        // the count badge needs the room.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(iconClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "herdr"
        }
        icon = IconController(statusItem: statusItem)

        events.onEvent = { [weak self] name, data in
            guard let self else { return }
            self.agents.apply(event: name, data: data)
            // AgentWatch only tracks blocked panes, but the badge and the panel
            // also show working and done — so re-read herdr, coalesced in case
            // a burst of transitions arrives at once.
            self.scheduleSnapshotRefresh()
        }
        events.onOpen = { [weak self] path in
            guard let self else { return }
            ProjectOpener.open(path: path, config: self.config)
        }
        events.onPicker = { [weak self] in
            guard let self else { return }
            ProjectOpener.chooseFolder(config: self.config)
        }
        events.onPanel = { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            // Asked for explicitly, so open it rather than toggling: a
            // keybinding pressed twice should leave the panel open.
            if !self.panel.isShown { self.panel.show(relativeTo: button) }
            self.acknowledgeWaiting()
        }
        events.statusProvider = { [weak self] in self?.statusPayload() ?? [:] }
        agents.onChange = { [weak self] in
            self?.refreshIcon()
            // An event that changes an agent's status changes what the panel
            // shows, if it happens to be open.
            self?.panel.refreshIfShown()
        }

        // The panel re-reads herdr each time it asks, so it stays live while
        // open — and the refresh keeps the icon in step for free.
        panel.snapshotProvider = { [weak self] in
            guard let self else { return nil }
            self.refreshState()
            return self.snapshot
        }
        panel.onSelectAgent = { [weak self] agent in
            guard let self else { return }
            ProjectOpener.focusAgent(paneId: agent.paneId, workspaceId: agent.workspaceId,
                                     config: self.config)
            self.acknowledgeWaiting()
        }
        panel.onSelectWorkspace = { [weak self] group in
            guard let self else { return }
            ProjectOpener.focusWorkspace(group.workspaceId, config: self.config)
            self.acknowledgeWaiting()
        }
        panel.onStartHerdr = { [weak self] in
            guard let self else { return }
            TerminalHost.launchHerdr(cwd: nil, config: self.config)
            TerminalHost.invalidateHostCache()
        }

        // Bringing herdr forward by any route — this icon, Cmd-Tab, clicking
        // the window — counts as having seen what is waiting.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        refreshState()
        startBackgroundRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        events.stop()
    }

    // MARK: - Icon interaction

    @objc private func iconClicked() {
        let isRightClick = NSApp.currentEvent.map {
            $0.type == .rightMouseUp || $0.modifierFlags.contains(.control)
        } ?? false

        // Left click opens the agents panel: which agents are running, in which
        // project, and what each is doing — with a click on a row focusing that
        // agent in herdr. Reading the panel counts as having seen what is
        // waiting, so the blink stops here too.
        if !isRightClick, let button = statusItem.button {
            panel.toggle(relativeTo: button)
            acknowledgeWaiting()
            return
        }

        refreshState()
        showMenu()
    }

    private func showMenu() {
        let menu = MenuBuilder.build(
            waiting: agents.sorted,
            hasClient: TerminalHost.hasVisibleClient(),
            blinkTimeout: config.blinkTimeoutSeconds,
            actions: menuActions())
        menu.delegate = self

        // The status item only owns a menu while one is being shown; otherwise
        // AppKit would open it on left click too and swallow the front action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuActions() -> MenuActions {
        MenuActions(
            startHerdr: { [weak self] in
                guard let self else { return }
                TerminalHost.launchHerdr(cwd: nil, config: self.config)
                TerminalHost.invalidateHostCache()
            },
            focusAgent: { [weak self] paneId, workspaceId in
                guard let self else { return }
                ProjectOpener.focusAgent(paneId: paneId, workspaceId: workspaceId,
                                         config: self.config)
                self.acknowledgeWaiting()
            },
            toggleLoginItem: { LoginItem.toggle() },
            setBlinkTimeout: { [weak self] seconds in
                guard let self else { return }
                self.config.blinkTimeoutSeconds = seconds
                self.config.save()
                // Re-arm against the new limit rather than waiting out the old.
                self.wasFlashing = false
                self.refreshIcon()
            },
            quit: { NSApp.terminate(nil) })
    }

    // MARK: - State

    /// Refresh the herdr-derived state the menu and icon read from.
    private func refreshState() {
        // Short timeout: this runs on the main thread right before the menu is
        // shown, and a wedged server must not freeze the menu bar.
        snapshot = HerdrClient.snapshot(timeout: 0.6)
        serverRunning = snapshot != nil
        agents.reconcile(with: snapshot)
        refreshIcon()
        panel.refreshIfShown()
    }

    /// herdr's status events cover blocked agents well, but not every state the
    /// badge shows, and an event can be missed while the app is not running —
    /// so re-read the whole picture on a slow beat. Twenty seconds is the
    /// reference plugin's closed-panel cadence.
    private static let backgroundRefreshInterval: TimeInterval = 20
    private var backgroundRefresh: Timer?
    private var pendingRefresh: Timer?

    private func startBackgroundRefresh() {
        let timer = Timer(timeInterval: Self.backgroundRefreshInterval,
                          repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundRefresh = timer
    }

    /// Coalesce a burst of hook events into one snapshot read.
    private func scheduleSnapshotRefresh() {
        pendingRefresh?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingRefresh = timer
    }

    private func refreshIcon() {
        let waiting = Set(agents.waiting.keys)
        // Forget acknowledgements for panes that are no longer waiting, so the
        // set cannot grow without bound.
        acknowledged.formIntersection(waiting)

        // The flash means "look at herdr". If herdr is already the frontmost
        // app, that has happened — there is no activation notification coming,
        // because no activation is needed.
        if !waiting.isEmpty && TerminalHost.isHostFrontmost() {
            acknowledged.formUnion(waiting)
        }

        let flashing = !waiting.isEmpty && !waiting.isSubset(of: acknowledged)

        // The badge counts every agent and takes the colour of the loudest
        // one; it disappears when they are all merely ready.
        let badge = snapshot?.badgeState().map { IconBadge(count: $0.count, state: $0.state) }

        if waiting.isEmpty {
            icon.set(.idle, badge: badge)
        } else if flashing {
            icon.set(.flashing, badge: badge)
        } else {
            icon.set(.acknowledged, badge: badge)
        }

        // Arm the deadline on the transition into blinking, not on every
        // refresh, or a burst of events would keep pushing it out.
        if flashing && !wasFlashing {
            armBlinkDeadline()
        } else if !flashing {
            blinkDeadline?.invalidate()
            blinkDeadline = nil
        }
        wasFlashing = flashing

        let count = waiting.count
        statusItem?.button?.toolTip = count == 0
            ? "herdr"
            : "herdr — \(count) agent\(count == 1 ? "" : "s") waiting for input"
    }

    /// Machine-readable state, used by `herdrbar-open --status`.
    private func statusPayload() -> [String: Any] {
        let host = TerminalHost.hostApplication()
        let iconState: String
        switch icon.state {
        case .idle: iconState = "idle"
        case .flashing: iconState = "flashing"
        case .acknowledged: iconState = "acknowledged"
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        return [
            "serverRunning": serverRunning,
            "iconState": iconState,
            "frontmostApp": frontmost?.bundleIdentifier ?? "",
            "frontmostPid": frontmost?.processIdentifier ?? 0,
            "hostFrontmost": TerminalHost.isHostFrontmost(),
            "blinkTimeoutSeconds": config.blinkTimeoutSeconds,
            "hostTerminal": host?.bundleIdentifier ?? "",
            "hostPid": host?.processIdentifier ?? 0,
            // The panel's rows, so `--status` explains what it would show.
            "agents": (snapshot?.agentRows() ?? []).map {
                [
                    "paneId": $0.paneId,
                    "workspaceId": $0.workspaceId,
                    "project": $0.project,
                    "tab": $0.tab ?? "",
                    "agent": $0.agent,
                    "status": $0.status,
                    "focused": $0.focused,
                ]
            },
            "waiting": agents.sorted.map {
                [
                    "agent": $0.agent,
                    "paneId": $0.paneId,
                    "workspaceId": $0.workspaceId,
                    "workspaceLabel": $0.workspaceLabel ?? "",
                    "menuTitle": $0.menuTitle,
                ]
            },
        ]
    }

    /// Let the blink run for the configured window, then settle to the badge.
    /// A timeout of 0 means the user wants it to blink until they click.
    private func armBlinkDeadline() {
        blinkDeadline?.invalidate()
        blinkDeadline = nil

        let seconds = config.blinkTimeoutSeconds
        guard seconds > 0 else { return }

        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            self?.acknowledgeWaiting()
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkDeadline = timer
    }

    /// Stop the flash: the user has looked at herdr.
    private func acknowledgeWaiting() {
        acknowledged.formUnion(agents.waiting.keys)
        refreshIcon()
    }

    @objc private func appActivated(_ notification: Notification) {
        guard !agents.isEmpty,
              let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                  as? NSRunningApplication,
              let host = TerminalHost.hostApplication(),
              activated.processIdentifier == host.processIdentifier
        else { return }
        acknowledgeWaiting()
    }

    // MARK: - Menu delegate

    func menuWillOpen(_ menu: NSMenu) {
        // Nothing to do: showMenu() already refreshed. Kept so future
        // resubmissions of the menu stay in one place.
    }

}

// `--diagnose` reports what the app can see, without touching the menu bar.
// Host detection walks the process tree, so this is the fastest way to explain
// a "clicking the icon does nothing" report.
if CommandLine.arguments.contains("--diagnose") {
    let config = Config.load()
    print("herdr binary   : \(config.herdrBinary)")
    print("terminal       : \(config.terminalBundleId)")
    print("herdr socket   : \(Paths.herdrSocket)")
    print("server running : \(HerdrClient.isRunning())")

    if let host = TerminalHost.hostApplication(useCache: false) {
        print("host terminal  : \(host.localizedName ?? "?") "
            + "(\(host.bundleIdentifier ?? "?"), pid \(host.processIdentifier))")
    } else {
        print("host terminal  : none — no attached herdr client found")
    }

    if let snapshot = HerdrClient.snapshot() {
        print("workspaces     : \(snapshot.workspaces.count)")
        for workspace in snapshot.workspaces {
            let path = snapshot.projectPath(for: workspace.workspaceId) ?? "-"
            print("  \(workspace.label)  \(path)")
        }
        let rows = snapshot.agentRows()
        print("agents         : \(rows.count)")
        for row in rows {
            let tab = row.tab.map { " · \($0)" } ?? ""
            print("  \(row.focused ? "▸" : " ") \(row.project)\(tab)  "
                + "\(row.agent) \(row.status)  [\(row.paneId)]")
        }
        let blocked = snapshot.panes.filter { $0.agentStatus == "blocked" }
        print("waiting agents : \(blocked.count)")
        for pane in blocked { print("  \(pane.agentName) in \(pane.workspaceId)") }
    }
    exit(0)
}

// An accessory app: menu bar only, no Dock tile and no menu bar menus.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
