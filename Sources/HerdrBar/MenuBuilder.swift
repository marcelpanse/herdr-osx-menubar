import AppKit

/// An NSMenuItem that carries its own handler, so the menu can be rebuilt
/// declaratively without a switch over tags or selectors.
final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

/// Everything the menu can do, supplied by the app delegate.
struct MenuActions {
    var startHerdr: () -> Void
    /// (pane_id, workspace_id) of the agent to focus.
    var focusAgent: (String, String) -> Void
    var toggleLoginItem: () -> Void
    var setBlinkTimeout: (Int) -> Void
    var quit: () -> Void
}

/// The right-click menu.
///
/// Deliberately short: the agents panel on left click is where herdr's state
/// lives, so this holds only what the panel cannot — starting herdr when none
/// is running, the two settings, and quitting.
enum MenuBuilder {

    static func build(waiting: [WaitingAgent],
                      hasClient: Bool,
                      blinkTimeout: Int,
                      actions: MenuActions) -> NSMenu {

        let menu = NSMenu()
        menu.autoenablesItems = false

        // MARK: Start
        // Only when there is nothing to go back to; with herdr already up, the
        // panel and its rows are the way in.
        if !hasClient {
            menu.addItem(BlockMenuItem(title: "Start herdr", handler: actions.startHerdr))
        }

        // MARK: Waiting agents
        if !waiting.isEmpty {
            addSeparatorIfNeeded(menu)
            menu.addItem(header("Waiting for Input"))

            for agent in waiting {
                let item = BlockMenuItem(title: agent.menuTitle) {
                    actions.focusAgent(agent.paneId, agent.workspaceId)
                }
                if let label = agent.workspaceLabel, !label.isEmpty {
                    // Project name as a dimmed trailing line, so a glance
                    // answers "which agent, in which project".
                    item.attributedTitle = twoPart(agent.menuTitle, label)
                }
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        // MARK: Settings
        addSeparatorIfNeeded(menu)

        let blink = NSMenuItem(title: "Blink Duration", action: nil, keyEquivalent: "")
        blink.submenu = blinkMenu(selected: blinkTimeout, actions: actions)
        menu.addItem(blink)

        let login = BlockMenuItem(title: "Start at Login", handler: actions.toggleLoginItem)
        login.state = LoginItem.isInstalled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(title: "Quit HerdrBar", keyEquivalent: "q",
                                   handler: actions.quit))
        return menu
    }

    // MARK: - Sections

    private static func blinkMenu(selected: Int, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for choice in Config.blinkTimeoutChoices {
            let item = BlockMenuItem(title: choice.title) {
                actions.setBlinkTimeout(choice.seconds)
            }
            item.state = choice.seconds == selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Presentation helpers

    /// Sections above this one are conditional, so a separator can only be
    /// added once there is something for it to separate.
    private static func addSeparatorIfNeeded(_ menu: NSMenu) {
        guard menu.numberOfItems > 0 else { return }
        menu.addItem(.separator())
    }

    /// A non-interactive caption row.
    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    /// "Primary   secondary" on one row, the secondary dimmed and smaller.
    private static func twoPart(_ primary: String, _ secondary: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: primary, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
        ])
        result.append(NSAttributedString(string: "   " + secondary, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }
}
