import Foundation

/// A pane as reported by `session.snapshot`.
struct PaneSnapshot {
    let paneId: String
    let workspaceId: String
    let cwd: String?
    let agent: String?
    let displayAgent: String?
    let agentStatus: String

    /// What to call the agent in the menu: herdr's own display name when it has
    /// one, otherwise the raw kind ("claude", "codex", ...).
    var agentName: String { displayAgent ?? agent ?? "agent" }
}

/// A workspace as reported by `session.snapshot`.
struct WorkspaceSnapshot {
    let workspaceId: String
    let label: String
    /// herdr's own ordering of the workspace list.
    let number: Int
    /// Repo root for worktree-backed workspaces; the project path we prefer.
    let repoRoot: String?
}

/// A tab as reported by `session.snapshot`. Only its label is interesting here:
/// it is what distinguishes two agents in the same project.
struct TabSnapshot {
    let tabId: String
    let workspaceId: String
    let label: String
    let number: Int

    /// herdr labels a tab with its own number until the user renames it, and a
    /// bare "3" says nothing in a list — so only a real name is worth showing.
    var isNamed: Bool { label != String(number) && !label.isEmpty }
}

/// An entry of the snapshot's `agents` array — herdr's own agent list, the same
/// data its in-terminal agents panel is drawn from.
struct AgentSnapshot {
    let paneId: String
    let workspaceId: String
    let tabId: String?
    let agent: String
    /// `idle`, `working`, `blocked`, `done` or `unknown`.
    let status: String
    /// True for the one agent herdr currently has focused.
    let focused: Bool
    let cwd: String?
    /// The pane's terminal title with herdr's status glyph stripped — what the
    /// agent is working on, and the panel's most useful line of text.
    let title: String?
}

/// One row of the agents panel: an agent, resolved against the workspace and
/// tab labels it belongs to.
struct AgentRow: Equatable {
    let paneId: String
    let workspaceId: String
    /// Project name — the row's primary text.
    let project: String
    /// Tab name, when the user named it. Shown dimmed after the project.
    let tab: String?
    let agent: String
    let status: String
    let focused: Bool
    let cwd: String?

    /// Status as a word, for the row's secondary line.
    var statusLabel: String { status == "unknown" ? "" : status }
}

struct Snapshot {
    let workspaces: [WorkspaceSnapshot]
    let panes: [PaneSnapshot]
    let tabs: [TabSnapshot]
    let agents: [AgentSnapshot]
    /// What herdr is showing right now — the panel marks it in bold.
    let focusedWorkspaceId: String?

    func workspace(_ id: String) -> WorkspaceSnapshot? {
        workspaces.first { $0.workspaceId == id }
    }

    func tab(_ id: String?) -> TabSnapshot? {
        guard let id else { return nil }
        return tabs.first { $0.tabId == id }
    }

    /// Best-effort project directory for a workspace: the worktree repo root if
    /// herdr tracks one, else the cwd of its first pane that has one.
    func projectPath(for workspaceId: String) -> String? {
        if let root = workspace(workspaceId)?.repoRoot, !root.isEmpty { return root }
        return panes.first { $0.workspaceId == workspaceId && $0.cwd != nil }?.cwd
    }

    /// The agents panel's rows, in herdr's own order: by workspace, then by tab,
    /// then by pane — so a row never moves unless herdr's layout does.
    func agentRows() -> [AgentRow] {
        let workspaceOrder = Dictionary(
            workspaces.map { ($0.workspaceId, $0.number) }, uniquingKeysWith: { a, _ in a })
        let tabOrder = Dictionary(
            tabs.map { ($0.tabId, $0.number) }, uniquingKeysWith: { a, _ in a })

        return agents
            .sorted {
                let leftWorkspace = workspaceOrder[$0.workspaceId] ?? Int.max
                let rightWorkspace = workspaceOrder[$1.workspaceId] ?? Int.max
                if leftWorkspace != rightWorkspace { return leftWorkspace < rightWorkspace }
                let leftTab = $0.tabId.flatMap { tabOrder[$0] } ?? Int.max
                let rightTab = $1.tabId.flatMap { tabOrder[$0] } ?? Int.max
                if leftTab != rightTab { return leftTab < rightTab }
                return $0.paneId < $1.paneId
            }
            .map { agent in
                let workspace = workspace(agent.workspaceId)
                let tab = tab(agent.tabId)
                return AgentRow(
                    paneId: agent.paneId,
                    workspaceId: agent.workspaceId,
                    project: workspace?.label ?? agent.workspaceId,
                    // Suppress a tab name that only repeats the project name.
                    tab: (tab?.isNamed == true && tab?.label != workspace?.label)
                        ? tab?.label : nil,
                    agent: agent.agent,
                    status: agent.status,
                    focused: agent.focused,
                    cwd: agent.cwd)
            }
    }
}

/// Client for herdr's socket API. Every call is a fresh short-lived connection;
/// herdr answers one response per connection, and there is no long-lived state
/// worth keeping open (agent state arrives via plugin hooks instead, because
/// `pane.agent_status_changed` cannot be subscribed to globally).
enum HerdrClient {

    private static func call(_ method: String, _ params: [String: Any] = [:],
                             timeout: TimeInterval = 3) -> [String: Any]? {
        let body: [String: Any] = ["id": "herdr-topbar", "method": method, "params": params]
        guard let reply = UnixSocket.request(path: Paths.herdrSocket, json: body, timeout: timeout)
        else { return nil }
        if reply["error"] != nil { return nil }
        return reply["result"] as? [String: Any]
    }

    /// Is a herdr server accepting connections right now?
    static func isRunning() -> Bool {
        call("ping", timeout: 1) != nil
    }

    /// `timeout` is kept short for menu-building calls: the socket is local and
    /// answers in microseconds, but the menu must never stall behind a wedged
    /// server.
    static func snapshot(timeout: TimeInterval = 3) -> Snapshot? {
        guard let result = call("session.snapshot", timeout: timeout),
              let snap = result["snapshot"] as? [String: Any] else { return nil }

        let workspaces = (snap["workspaces"] as? [[String: Any]] ?? []).compactMap {
            ws -> WorkspaceSnapshot? in
            guard let id = ws["workspace_id"] as? String else { return nil }
            let worktree = ws["worktree"] as? [String: Any]
            return WorkspaceSnapshot(
                workspaceId: id,
                label: ws["label"] as? String ?? id,
                number: ws["number"] as? Int ?? Int.max,
                repoRoot: worktree?["repo_root"] as? String)
        }

        let panes = (snap["panes"] as? [[String: Any]] ?? []).compactMap {
            p -> PaneSnapshot? in
            guard let id = p["pane_id"] as? String,
                  let wsId = p["workspace_id"] as? String else { return nil }
            return PaneSnapshot(
                paneId: id,
                workspaceId: wsId,
                cwd: p["cwd"] as? String,
                agent: p["agent"] as? String,
                displayAgent: p["display_agent"] as? String,
                agentStatus: p["agent_status"] as? String ?? "unknown")
        }

        let tabs = (snap["tabs"] as? [[String: Any]] ?? []).compactMap {
            t -> TabSnapshot? in
            guard let id = t["tab_id"] as? String,
                  let wsId = t["workspace_id"] as? String else { return nil }
            let number = t["number"] as? Int ?? Int.max
            return TabSnapshot(
                tabId: id,
                workspaceId: wsId,
                label: t["label"] as? String ?? String(number),
                number: number)
        }

        let agents = (snap["agents"] as? [[String: Any]] ?? []).compactMap {
            a -> AgentSnapshot? in
            guard let paneId = a["pane_id"] as? String,
                  let wsId = a["workspace_id"] as? String else { return nil }
            return AgentSnapshot(
                paneId: paneId,
                workspaceId: wsId,
                tabId: a["tab_id"] as? String,
                agent: (a["display_agent"] as? String) ?? (a["agent"] as? String) ?? "agent",
                status: a["agent_status"] as? String ?? "unknown",
                focused: a["focused"] as? Bool ?? false,
                cwd: a["cwd"] as? String,
                title: (a["terminal_title_stripped"] as? String)
                    ?? (a["terminal_title"] as? String))
        }

        return Snapshot(
            workspaces: workspaces, panes: panes, tabs: tabs, agents: agents,
            focusedWorkspaceId: snap["focused_workspace_id"] as? String)
    }

    /// Create a workspace rooted at `path` and focus it. Returns false when the
    /// server is not reachable, so the caller can fall back to launching herdr.
    @discardableResult
    static func createWorkspace(cwd: String, label: String?) -> Bool {
        var params: [String: Any] = ["cwd": cwd, "focus": true]
        if let label { params["label"] = label }
        return call("workspace.create", params) != nil
    }

    @discardableResult
    static func focusWorkspace(_ workspaceId: String) -> Bool {
        call("workspace.focus", ["workspace_id": workspaceId]) != nil
    }

    /// Focus one agent, exactly as selecting its row inside herdr does. The
    /// target is the agent's `pane_id` — herdr resolves no other form (a
    /// workspace label or a bare "claude" both come back `agent_not_found`).
    @discardableResult
    static func focusAgent(paneId: String) -> Bool {
        call("agent.focus", ["target": paneId]) != nil
    }
}
