import Foundation

/// How an agent is doing, in the panel's own vocabulary.
///
/// herdr reports `blocked`/`done`/`working`/`idle`; this is the display side of
/// that, and the order of the cases is the order that matters — waiting beats
/// finished beats busy, wherever a workspace has to be summed up in one word.
enum AgentState: Int, Comparable {
    /// herdr `idle`: ready for input, and nothing to report.
    case ready = 0
    case working = 1
    /// herdr `done`: finished work that has not been looked at yet.
    case done = 2
    /// herdr `blocked`: the agent is waiting on an answer.
    case needsYou = 3

    static func < (lhs: AgentState, rhs: AgentState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(herdrStatus: String) {
        switch herdrStatus {
        case "blocked": self = .needsYou
        case "done": self = .done
        case "working": self = .working
        default: self = .ready
        }
    }

    var word: String {
        switch self {
        case .needsYou: return "needs you"
        case .done: return "done"
        case .working: return "working"
        case .ready: return "ready"
        }
    }

    /// The two states worth interrupting someone for are set in bold.
    var isLoud: Bool { self == .needsYou || self == .done }

    /// Nothing to say when every agent is merely ready — the menu bar badge
    /// disappears entirely rather than showing a resting count.
    var isQuiet: Bool { self == .ready }
}

/// One agent line in the panel.
struct PanelAgent: Equatable {
    let paneId: String
    let workspaceId: String
    /// The terminal title — what the agent is working on. Falls back to the
    /// agent's kind when the pane has no title worth showing.
    let title: String
    let state: AgentState
}

/// One workspace block: a header, a dim line of the projects inside it, and the
/// agents beneath.
struct PanelGroup: Equatable {
    let workspaceId: String
    let label: String
    /// True when herdr is showing this workspace — drawn bold, as the reference
    /// does for a session that already has a window on screen.
    let focused: Bool
    /// The projects this workspace's agents are sitting in.
    let detail: String
    let agents: [PanelAgent]

    /// The loudest state among the agents, which colours the group's dot and
    /// its summary. Nil for a workspace with no agents at all.
    var loudest: AgentState? { agents.map(\.state).max() }

    /// How many agents share the loudest state, for "2 done", "1 needs you".
    var loudestCount: Int {
        guard let loudest else { return 0 }
        return agents.filter { $0.state == loudest }.count
    }

    var agentCountLabel: String {
        agents.count == 1 ? "1 agent" : "\(agents.count) agents"
    }
}

extension Snapshot {

    /// The panel's contents: every workspace, in herdr's order, with its agents
    /// nested underneath.
    ///
    /// Workspaces with no agents are kept — that is the reference plugin's
    /// point, that a session you cannot see is still there — and render dimmed
    /// with nothing below them.
    func panelGroups() -> [PanelGroup] {
        let byWorkspace = Dictionary(grouping: agents, by: \.workspaceId)

        return workspaces.sorted { $0.number < $1.number }.map { workspace in
            let members = (byWorkspace[workspace.workspaceId] ?? []).sorted {
                // Loudest first, so what needs attention is never below the
                // fold of a long workspace.
                let left = AgentState(herdrStatus: $0.status)
                let right = AgentState(herdrStatus: $1.status)
                if left != right { return left > right }
                return $0.paneId < $1.paneId
            }

            return PanelGroup(
                workspaceId: workspace.workspaceId,
                label: workspace.label,
                focused: workspace.workspaceId == focusedWorkspaceId,
                detail: detailLine(for: workspace, agents: members),
                agents: members.map { agent in
                    PanelAgent(
                        paneId: agent.paneId,
                        workspaceId: agent.workspaceId,
                        title: agentTitle(agent),
                        state: AgentState(herdrStatus: agent.status))
                })
        }
    }

    /// The dim second line: the distinct project directories the workspace's
    /// agents are working in. When that says nothing the workspace's label does
    /// not already say — the usual single-project case — fall back to the path,
    /// which at least tells you *which* checkout this is.
    private func detailLine(for workspace: WorkspaceSnapshot,
                            agents: [AgentSnapshot]) -> String {
        var seen = Set<String>()
        let projects = agents
            .compactMap { $0.cwd.map { ($0 as NSString).lastPathComponent } }
            .filter { $0 != workspace.label && seen.insert($0).inserted }

        if !projects.isEmpty { return projects.joined(separator: "  ·  ") }

        guard let path = projectPath(for: workspace.workspaceId) else {
            return agents.isEmpty ? "no agents" : workspace.label
        }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// A pane's terminal title is what the agent is doing; its kind is the
    /// fallback when there is no title to show.
    private func agentTitle(_ agent: AgentSnapshot) -> String {
        let title = agent.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? agent.agent : title
    }

    /// The menu bar badge: how many agents there are, coloured by the loudest
    /// one — and nothing at all when they are all merely ready.
    func badgeState() -> (count: Int, state: AgentState)? {
        guard !agents.isEmpty else { return nil }
        let loudest = agents.map { AgentState(herdrStatus: $0.status) }.max() ?? .ready
        guard !loudest.isQuiet else { return nil }
        return (agents.count, loudest)
    }
}
