import AppKit

/// Colours, type and spacing for the agents panel.
///
/// The panel is a fixed dark surface in either system appearance rather than a
/// vibrant native popover, and it is set in monospace throughout: it shows
/// terminal titles from a terminal workspace manager, and it is modelled on
/// jankeesvw/omarchy-herdr, which does the same job on Linux.
enum PanelTheme {

    // MARK: Colour

    static let background = NSColor(srgbRed: 0.086, green: 0.106, blue: 0.157, alpha: 1)
    static let border = NSColor(srgbRed: 0.353, green: 0.647, blue: 1.000, alpha: 1)
    static let separator = NSColor(white: 1, alpha: 0.10)
    static let hover = NSColor(white: 1, alpha: 0.055)

    static let primary = NSColor(srgbRed: 0.902, green: 0.922, blue: 0.961, alpha: 1)
    static let agentText = NSColor(srgbRed: 0.776, green: 0.808, blue: 0.871, alpha: 1)
    static let dim = NSColor(srgbRed: 0.435, green: 0.475, blue: 0.576, alpha: 1)

    static let working = NSColor(srgbRed: 0.310, green: 0.620, blue: 1.000, alpha: 1)
    static let needsYou = NSColor(srgbRed: 0.957, green: 0.251, blue: 0.369, alpha: 1)
    static let done = NSColor(srgbRed: 0.204, green: 0.831, blue: 0.533, alpha: 1)

    static func color(for state: AgentState) -> NSColor {
        switch state {
        case .needsYou: return needsYou
        case .done: return done
        case .working: return working
        case .ready: return dim
        }
    }

    // MARK: Type

    static let titleFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let groupFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
    static let groupFontIdle = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let detailFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let agentFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let statusFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let statusFontLoud = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)

    // MARK: Metrics

    static let width: CGFloat = 400
    static let cornerRadius: CGFloat = 10
    static let borderWidth: CGFloat = 2

    static let paddingTop: CGFloat = 12
    static let paddingBottom: CGFloat = 12
    static let sideInset: CGFloat = 16

    static let titleHeight: CGFloat = 18
    static let separatorGap: CGFloat = 8

    static let groupHeaderHeight: CGFloat = 23
    static let detailHeight: CGFloat = 18
    static let agentHeight: CGFloat = 21
    static let groupSpacing: CGFloat = 12

    /// Left edges: the dots sit in a gutter, the text lines up behind them.
    static let groupDotCenterX: CGFloat = 30
    static let groupTextX: CGFloat = 44
    static let agentDotCenterX: CGFloat = 48
    static let agentTextX: CGFloat = 60

    static let groupDotDiameter: CGFloat = 8
    static let agentDotDiameter: CGFloat = 6

    /// Highlight inset for a hovered row.
    static let rowHighlightInset: CGFloat = 8

    /// Never taller than this, whatever the screen allows.
    static let maxHeight: CGFloat = 560
}

// MARK: - Panel

/// The agents panel: what a left click on the menu bar icon opens.
///
/// One block per workspace — its label, the projects inside it, and every agent
/// with what it is working on and how it is doing. Clicking a workspace focuses
/// it; clicking an agent focuses that agent, which is the same operation as
/// selecting its row inside herdr.
///
/// This is a borderless `NSPanel` rather than an `NSPopover` because the look is
/// a fully custom dark surface with its own border, and a popover insists on
/// drawing its own material and arrow around whatever it contains.
final class AgentsPanel: NSObject {

    /// An agent line was clicked.
    var onSelectAgent: ((PanelAgent) -> Void)?
    /// A workspace header was clicked.
    var onSelectWorkspace: ((PanelGroup) -> Void)?
    /// "start herdr" from the panel's empty state.
    var onStartHerdr: (() -> Void)?
    /// Fresh state, read on open and while the panel is showing.
    var snapshotProvider: (() -> Snapshot?)?

    /// The reference plugin's cadence: three seconds while the panel is open.
    /// (Twenty seconds while closed is the app's own icon refresh, not this.)
    private static let pollInterval: TimeInterval = 3

    private var window: PanelWindow?
    private let content = PanelContentView()
    private var poll: Timer?
    private var outsideClickMonitor: Any?
    /// Where the menu bar icon was when the panel opened, so a panel that grows
    /// or shrinks on refresh stays anchored to it.
    private var anchor: NSRect = .zero

    var isShown: Bool { window?.isVisible ?? false }

    override init() {
        super.init()
        content.snapshotProvider = { [weak self] in self?.snapshotProvider?() }
        content.onSelectAgent = { [weak self] agent in
            // Close first: the click's outcome is a terminal coming forward,
            // and a panel left hanging over it looks like a stuck window.
            self?.close()
            self?.onSelectAgent?(agent)
        }
        content.onSelectWorkspace = { [weak self] group in
            self?.close()
            self?.onSelectWorkspace?(group)
        }
        content.onStartHerdr = { [weak self] in
            self?.close()
            self?.onStartHerdr?()
        }
        content.onEscape = { [weak self] in self?.close() }
        content.onLayoutChange = { [weak self] in self?.reposition() }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown { close() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let window = self.window ?? makeWindow()
        self.window = window

        content.reload()
        reposition()

        // A non-activating panel takes clicks and keys without pulling the app
        // forward, so opening the panel never steals focus from the terminal.
        window.makeKeyAndOrderFront(nil)

        poll?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.isShown else { return }
            self.content.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer

        // A borderless panel gets no "clicked away" event of its own. Global
        // monitors only see events aimed at other applications, which is
        // exactly the definition of "outside".
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        poll?.invalidate()
        poll = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        window?.orderOut(nil)
    }

    /// Pull in new state pushed from outside (a forwarded hook event), but only
    /// while the panel is actually on screen.
    func refreshIfShown() {
        guard isShown else { return }
        content.reload()
    }

    private func makeWindow() -> PanelWindow {
        let window = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: PanelTheme.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Above ordinary windows, at the level menus use, so it is never buried
        // under the terminal it is about to bring forward.
        window.level = .popUpMenu
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = content
        return window
    }

    /// Hang the panel under the menu bar icon, nudged inside the screen edge.
    private func reposition() {
        guard let window else { return }
        let height = content.contentHeight
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchor.midX - PanelTheme.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - PanelTheme.width - 8)
        let y = max(anchor.minY - height - 6, visible.minY + 8)

        window.setFrame(NSRect(x: x, y: y, width: PanelTheme.width, height: height),
                        display: true)
    }
}

/// Borderless panels refuse key status by default, which would leave Escape
/// dead and the rows unable to take a click without activating the app.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Contents

/// The panel's dark rounded surface, and the rows inside it.
final class PanelContentView: NSView {

    var snapshotProvider: (() -> Snapshot?)?
    var onSelectAgent: ((PanelAgent) -> Void)?
    var onSelectWorkspace: ((PanelGroup) -> Void)?
    var onStartHerdr: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Fired when a reload changed the panel's height.
    var onLayoutChange: (() -> Void)?

    private let scroll = NSScrollView()
    private let list = FlippedView()

    private(set) var contentHeight: CGFloat = 200

    private var rendered: [PanelGroup]?
    private var renderedServerRunning: Bool?
    /// Guards the one reentrant path: asking for a snapshot refreshes the app's
    /// agent state, which can fire the change callback that asks the panel to
    /// reload again — mid-reload.
    private var reloading = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = PanelTheme.background.cgColor
        layer?.cornerRadius = PanelTheme.cornerRadius
        layer?.borderWidth = PanelTheme.borderWidth
        layer?.borderColor = PanelTheme.border.cgColor
        layer?.masksToBounds = true

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.knobStyle = .light
        scroll.documentView = list
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape; a panel with no title bar has no other way to dismiss.
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    // MARK: Reload

    func reload() {
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }

        let snapshot = snapshotProvider?()
        let groups = snapshot?.panelGroups() ?? []
        let running = snapshot != nil

        // Rebuilding on every poll would drop hover highlighting and reset the
        // scroll position mid-read, so only redraw a list that actually moved.
        guard groups != rendered || running != renderedServerRunning else { return }
        rendered = groups
        renderedServerRunning = running

        list.subviews.forEach { $0.removeFromSuperview() }

        let previousHeight = contentHeight
        let listHeight = running ? layoutGroups(groups) : layoutNotRunning()

        let total = PanelTheme.paddingTop + PanelTheme.titleHeight
            + PanelTheme.separatorGap * 2 + 1 + listHeight + PanelTheme.paddingBottom
        contentHeight = min(total, PanelTheme.maxHeight)

        let listVisible = contentHeight - (total - listHeight)
        list.frame = NSRect(x: 0, y: 0, width: PanelTheme.width, height: listHeight)
        scroll.frame = NSRect(x: 0, y: PanelTheme.paddingBottom,
                              width: PanelTheme.width, height: max(listVisible, 0))
        list.scroll(.zero)

        titleText = titleLine(snapshot: snapshot, groups: groups, running: running)
        needsDisplay = true

        if contentHeight != previousHeight { onLayoutChange?() }
    }

    /// Lays out one block per workspace and answers the total height used.
    private func layoutGroups(_ groups: [PanelGroup]) -> CGFloat {
        guard !groups.isEmpty else {
            return layoutMessage("no workspaces open")
        }

        var y: CGFloat = 0
        for (index, group) in groups.enumerated() {
            if index > 0 { y += PanelTheme.groupSpacing }

            let headerHeight = PanelTheme.groupHeaderHeight
                + (group.detail.isEmpty ? 0 : PanelTheme.detailHeight)
            let header = PanelGroupRow(
                group: group,
                frame: NSRect(x: 0, y: y, width: PanelTheme.width, height: headerHeight)
            ) { [weak self] in self?.onSelectWorkspace?(group) }
            list.addSubview(header)
            y += headerHeight

            for agent in group.agents {
                let row = PanelAgentRow(
                    agent: agent,
                    frame: NSRect(x: 0, y: y, width: PanelTheme.width,
                                  height: PanelTheme.agentHeight)
                ) { [weak self] in self?.onSelectAgent?(agent) }
                list.addSubview(row)
                y += PanelTheme.agentHeight
            }
        }
        return y
    }

    private func layoutNotRunning() -> CGFloat {
        var y = layoutMessage("herdr is not running")
        let start = PanelActionRow(
            title: "start herdr",
            frame: NSRect(x: 0, y: y, width: PanelTheme.width,
                          height: PanelTheme.agentHeight)
        ) { [weak self] in self?.onStartHerdr?() }
        list.addSubview(start)
        y += PanelTheme.agentHeight
        return y
    }

    private func layoutMessage(_ text: String) -> CGFloat {
        let label = PanelMessageRow(
            text: text,
            frame: NSRect(x: 0, y: 0, width: PanelTheme.width,
                          height: PanelTheme.groupHeaderHeight))
        list.addSubview(label)
        return PanelTheme.groupHeaderHeight
    }

    // MARK: Header

    private var titleText = "herdr"

    private func titleLine(snapshot: Snapshot?, groups: [PanelGroup],
                           running: Bool) -> String {
        guard running else { return "herdr (not running)" }
        let workspaces = groups.count
        let agents = groups.reduce(0) { $0 + $1.agents.count }
        let workspaceWord = workspaces == 1 ? "workspace" : "workspaces"
        let agentWord = agents == 1 ? "agent" : "agents"
        return "herdr (\(workspaces) \(workspaceWord), \(agents) \(agentWord))"
    }

    override func draw(_ dirtyRect: NSRect) {
        // Title and separator are drawn rather than laid out: they never move
        // relative to the top of the panel, and neither is interactive.
        let titleY = bounds.maxY - PanelTheme.paddingTop - PanelTheme.titleHeight
        PanelText.draw(titleText, font: PanelTheme.titleFont, color: PanelTheme.dim,
                       in: NSRect(x: PanelTheme.sideInset, y: titleY,
                                  width: PanelTheme.width - PanelTheme.sideInset * 2,
                                  height: PanelTheme.titleHeight))

        PanelTheme.separator.setFill()
        NSRect(x: PanelTheme.sideInset,
               y: titleY - PanelTheme.separatorGap,
               width: PanelTheme.width - PanelTheme.sideInset * 2,
               height: 1).fill()
    }
}

/// Top-down coordinates, so rows can be laid out in reading order.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Text drawing

/// Single-line text drawing, vertically centred in its rect.
///
/// The panel draws its own text rather than stacking `NSTextField`s: every line
/// is one or two runs with a right-aligned tail, and a field per run would be
/// more plumbing than drawing for no gain.
enum PanelText {

    static func attributed(_ text: String, font: NSFont, color: NSColor,
                           alignment: NSTextAlignment = .left,
                           truncating: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = truncating ? .byTruncatingTail : .byClipping
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }

    @discardableResult
    static func draw(_ text: String, font: NSFont, color: NSColor,
                     in rect: NSRect, alignment: NSTextAlignment = .left,
                     truncating: Bool = false) -> CGFloat {
        let string = attributed(text, font: font, color: color,
                                alignment: alignment, truncating: truncating)
        draw(string, in: rect)
        return string.size().width
    }

    static func draw(_ string: NSAttributedString, in rect: NSRect) {
        let height = string.size().height
        let centred = NSRect(x: rect.minX, y: rect.midY - height / 2,
                             width: rect.width, height: height)
        string.draw(with: centred, options: [.usesLineFragmentOrigin])
    }

    static func dot(_ color: NSColor, centerX: CGFloat, centerY: CGFloat,
                    diameter: CGFloat) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: centerX - diameter / 2, y: centerY - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }
}

// MARK: - Rows

/// Shared hover highlight and click handling.
class PanelRow: NSView {

    private let action: (() -> Void)?
    private(set) var hovering = false

    init(frame: NSRect, action: (() -> Void)?) {
        self.action = action
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard action != nil else { return }
        // `.activeAlways`: the panel takes clicks without activating the app,
        // so hover must work while another application is frontmost.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    /// Claim the mouse-down — AppKit delivers the matching mouse-up to whatever
    /// accepted the down, so without this `mouseUp` never arrives here.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        // Only a click that both started and ended on this row counts, so a
        // drag out of the panel does not focus anything by accident.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    func drawHover() {
        guard hovering else { return }
        PanelTheme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: PanelTheme.rowHighlightInset, dy: 1),
                     xRadius: 5, yRadius: 5).fill()
    }
}

/// A workspace block's header: dot, label, right-aligned summary, and the dim
/// line of projects underneath.
final class PanelGroupRow: PanelRow {

    private let group: PanelGroup

    init(group: PanelGroup, frame: NSRect, action: @escaping () -> Void) {
        self.group = group
        super.init(frame: frame, action: action)
        toolTip = group.detail.isEmpty ? group.label : "\(group.label) — \(group.detail)"
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHover()

        let headerRect = NSRect(x: 0, y: bounds.maxY - PanelTheme.groupHeaderHeight,
                                width: bounds.width, height: PanelTheme.groupHeaderHeight)
        let state = group.loudest

        PanelText.dot(state.map(PanelTheme.color(for:)) ?? PanelTheme.dim,
                      centerX: PanelTheme.groupDotCenterX, centerY: headerRect.midY,
                      diameter: PanelTheme.groupDotDiameter)

        // Bold for the workspace herdr is showing, as the reference does for a
        // session that already has a window up.
        let summary = summaryText(state: state)
        let summaryWidth = summary.size().width
        let labelWidth = bounds.width - PanelTheme.groupTextX
            - summaryWidth - PanelTheme.sideInset - 12
        PanelText.draw(group.label,
                       font: group.focused ? PanelTheme.groupFont : PanelTheme.groupFontIdle,
                       color: group.agents.isEmpty ? PanelTheme.dim : PanelTheme.primary,
                       in: NSRect(x: PanelTheme.groupTextX, y: headerRect.minY,
                                  width: max(labelWidth, 40), height: headerRect.height),
                       truncating: true)

        PanelText.draw(summary, in: NSRect(
            x: bounds.width - PanelTheme.sideInset - summaryWidth,
            y: headerRect.minY, width: summaryWidth, height: headerRect.height))

        guard !group.detail.isEmpty else { return }
        PanelText.draw(group.detail, font: PanelTheme.detailFont, color: PanelTheme.dim,
                       in: NSRect(x: PanelTheme.groupTextX, y: bounds.minY,
                                  width: bounds.width - PanelTheme.groupTextX
                                      - PanelTheme.sideInset,
                                  height: PanelTheme.detailHeight),
                       truncating: true)
    }

    /// "1 needs you" in the state's colour, then "2 agents" dimmed — or just
    /// "no agents" for a workspace with none.
    private func summaryText(state: AgentState?) -> NSAttributedString {
        guard let state else {
            return PanelText.attributed("no agents", font: PanelTheme.statusFont,
                                        color: PanelTheme.dim)
        }
        let result = NSMutableAttributedString(attributedString: PanelText.attributed(
            "\(group.loudestCount) \(state.word)",
            font: state.isLoud ? PanelTheme.statusFontLoud : PanelTheme.statusFont,
            color: PanelTheme.color(for: state)))
        result.append(PanelText.attributed("  " + group.agentCountLabel,
                                           font: PanelTheme.statusFont,
                                           color: PanelTheme.dim))
        return result
    }
}

/// One agent line: dot, what it is working on, and its state.
final class PanelAgentRow: PanelRow {

    private let agent: PanelAgent

    init(agent: PanelAgent, frame: NSRect, action: @escaping () -> Void) {
        self.agent = agent
        super.init(frame: frame, action: action)
        toolTip = "\(agent.title) — \(agent.state.word)"
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHover()

        let color = PanelTheme.color(for: agent.state)
        PanelText.dot(color, centerX: PanelTheme.agentDotCenterX, centerY: bounds.midY,
                      diameter: PanelTheme.agentDotDiameter)

        let status = PanelText.attributed(
            agent.state.word,
            font: agent.state.isLoud ? PanelTheme.statusFontLoud : PanelTheme.statusFont,
            color: color)
        let statusWidth = status.size().width

        PanelText.draw(agent.title, font: PanelTheme.agentFont,
                       color: PanelTheme.agentText,
                       in: NSRect(x: PanelTheme.agentTextX, y: bounds.minY,
                                  width: bounds.width - PanelTheme.agentTextX
                                      - statusWidth - PanelTheme.sideInset - 12,
                                  height: bounds.height),
                       truncating: true)

        PanelText.draw(status, in: NSRect(
            x: bounds.width - PanelTheme.sideInset - statusWidth,
            y: bounds.minY, width: statusWidth, height: bounds.height))
    }
}

/// A dim, non-interactive line — the empty states.
final class PanelMessageRow: PanelRow {

    private let text: String

    init(text: String, frame: NSRect) {
        self.text = text
        super.init(frame: frame, action: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        PanelText.draw(text, font: PanelTheme.agentFont, color: PanelTheme.dim,
                       in: NSRect(x: PanelTheme.groupTextX, y: bounds.minY,
                                  width: bounds.width - PanelTheme.groupTextX
                                      - PanelTheme.sideInset,
                                  height: bounds.height))
    }
}

/// A clickable line in the panel's own type — used for "start herdr".
final class PanelActionRow: PanelRow {

    private let title: String

    init(title: String, frame: NSRect, action: @escaping () -> Void) {
        self.title = title
        super.init(frame: frame, action: action)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHover()
        PanelText.draw(title, font: PanelTheme.agentFont, color: PanelTheme.working,
                       in: NSRect(x: PanelTheme.groupTextX, y: bounds.minY,
                                  width: bounds.width - PanelTheme.groupTextX
                                      - PanelTheme.sideInset,
                                  height: bounds.height))
    }
}
