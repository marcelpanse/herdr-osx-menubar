# herdr-osx-menubar

A macOS menu bar companion for [herdr](https://herdr.dev).

herdr lives inside the terminal. This plugin puts a small icon in the menu bar so
you can see every agent from anywhere, jump straight to the one you want, and
tell at a glance when one is waiting for you.

## What it does

**Left click** opens the **agents panel**: every workspace, the projects inside
it, and every agent with what it is working on and how it is doing.

```
┌────────────────────────────────────────────┐
│  herdr (3 workspaces, 3 agents)            │
│  ────────────────────────────────────────  │
│   ●  quietjar.com                no agents │
│      ~/Documents/Sources/quietjar.com      │
│   ●  unless.com          2 ready  2 agents │
│      ~/Documents/Sources/unless.com        │
│      ●  Claude Code                  ready │
│      ●  claude attach 08961447       ready │
│   ●  herdr-osx-menubar  1 working  1 agent │
│      ~/Documents/Sources/herdr-osx-menubar │
│      ●  Herdr plugin changes       working │
└────────────────────────────────────────────┘
```

- **Workspace header** — its label, bold when herdr is currently showing it, and
  a summary on the right: how many agents share the loudest status, then the
  total. Clicking it focuses that workspace.
- **The dim line** beneath is the projects the workspace's agents are working in.
- **Agent lines** carry the pane's terminal title — what the agent is actually
  doing — and its status. Clicking one focuses that agent, exactly as selecting
  its row inside herdr does, and brings the terminal forward.
- Workspaces with no agents stay listed, dimmed, so a project you have open but
  forgotten about is still visible.
- Blocks follow herdr's own workspace order, the same as its sidebar — so an
  empty workspace can sit above a busy one. Agents *within* a block are sorted
  loudest first, so what needs attention is never below the fold.

Statuses, in the order that matters when a workspace has to be summed up in one
word — waiting beats finished beats busy:

| Panel | herdr | Meaning |
|---|---|---|
| **needs you** | `blocked` | The agent is waiting on an answer |
| **done** | `done` | Finished work you have not looked at yet |
| working | `working` | Busy |
| ready | `idle` | Ready for input, nothing to report |

The panel re-reads herdr every three seconds while it is open, so a status that
changes under you is reflected without closing it. Escape or a click anywhere
outside dismisses it. Opening it never steals focus from your terminal.

**Right click** opens a short menu — the panel is where herdr's state lives, so
this holds only what the panel cannot:

- **Start herdr** — only when nothing is attached, since with herdr up the panel
  is the way in
- **Waiting for Input** — which agent is waiting, and in which project
- **Blink Duration**, **Start at Login**
- **Quit HerdrBar**

### The icon and its badge

**At rest the icon is an AppKit template image**, so it behaves like every other
icon in the menu bar: white on a dark bar, black on a light one, inverted while
its menu is open, and correct under Increase Contrast.

**A count badge** sits beside it whenever herdr has agents that are not merely
idle — the number of agents, in the colour of the loudest one: red for
`needs you`, green for `done`, amber for `working`. When everything is idle there
is nothing to say, so the badge disappears.

It is drawn as an overlay next to the ram rather than baked into the icon,
because a template image is painted in a single tint and a badge inside it would
come out monochrome.

**An agent waiting for input** makes the icon swap to the badge's colour and back,
three times a second. It stops as soon as herdr comes to the front — by a panel
row, by Cmd-Tab, or by clicking the window — and leaves the badge while the agent
is still waiting. A *different* agent blocking later starts the blink again.

It also stops on its own after **Blink Duration**, so an agent left waiting
overnight is not still blinking in the morning:

| Choice | Behaviour |
|---|---|
| 1 minute | Blink for a minute, then hold the badge |
| **3 minutes** | Default |
| 10 minutes | For longer unattended runs |
| Until clicked | Never stops on its own |

The badge stays either way — only the movement stops.

### About notifications

herdr already delivers its own notifications (`[ui.toast]`, `[ui.sound]` in
`config.toml`). **This plugin posts none and changes none of that.** It only
makes an existing "agent is waiting" state easy to notice from across the screen.
Your herdr notification settings are left exactly as you have them.

## Install

```bash
git clone https://github.com/marcelpanse/herdr-osx-menubar.git
cd herdr-osx-menubar

herdr plugin link "$PWD"
bash scripts/build.sh
bash scripts/install-login-item.sh
```

Or install it straight from GitHub, which runs the build step for you:

```bash
herdr plugin install marcelpanse/herdr-osx-menubar
```

`herdr plugin install` runs `scripts/build.sh` for you, but **`herdr plugin link`
does not run build steps** — so when working on a linked copy, run `build.sh`
yourself after changing any Swift source, then `scripts/restart-bar.sh`.

`install-login-item.sh` is what keeps the icon in the menu bar while herdr is
closed. The plugin's `[[startup]]` hook only fires when a herdr server starts,
which cannot cover the "herdr is closed, click the icon to start it" case.

## Plugin actions

| Action | What it does |
|---|---|
| `open-panel` | Show the agents panel |
| `open-picker` | Show the folder picker |
| `install-login-item` | Install the start-at-login LaunchAgent |
| `restart-bar` | Restart the menu bar app after a rebuild |

Bind either of the first two to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+a"
type = "plugin_action"
command = "herdr-osx-menubar.open-panel"
description = "show the agents panel"

[[keys.command]]
key = "prefix+o"
type = "plugin_action"
command = "herdr-osx-menubar.open-picker"
description = "open a folder in herdr"
```

## The icon artwork

The menu bar glyph is herdr's own ram, from
[`herdr.dev/assets/ram.svg`](https://herdr.dev/assets/ram.svg). The source SVG is
kept at `Resources/ram.svg`; `scripts/make-icon.sh` crops it to the ram's head
and writes the vector PDF the app actually bundles.

The crop matters: in the full mark the ram's body runs off the frame as a solid
mass, which at menu bar size collapses into an unreadable block. Cropping to the
head keeps the curled horn and the `>-` prompt face — the parts that identify it
at 17pt. Regenerate after changing the artwork or the crop:

```bash
bash scripts/make-icon.sh && bash scripts/build.sh
```

## Configuration

`~/Library/Application Support/dev.herdr.topbar/config.json`:

```json
{
  "herdrBinary": "/opt/homebrew/bin/herdr",
  "terminalBundleId": "com.apple.Terminal",
  "blinkTimeoutSeconds": 180
}
```

`blinkTimeoutSeconds` mirrors the Blink Duration menu; `0` means "until
clicked". Editing it here works too, but the app reads it at launch, so restart
with `scripts/restart-bar.sh` after a manual edit.

`terminalBundleId` is only used to *launch* a new herdr. Bringing an existing one
to the front works by finding whatever terminal actually hosts the herdr process,
so switching terminals needs no configuration.

## How it works

```
you       ──left click──▶  HerdrBar ──JSON/unix────▶ herdr.sock  (session.snapshot)
panel row ──click───────▶  HerdrBar ──JSON/unix────▶ herdr.sock  (agent.focus)
                                    ──process tree──▶ Terminal.activate()
CLI       ──herdrbar-open▶  HerdrBar ──JSON/unix────▶ herdr.sock  (workspace.create)
herdr     ──[[events]]──▶  forward-event.sh ───────▶ HerdrBar  (badge, blink)
```

Four design notes worth knowing:

**Fronting the terminal uses no permissions.** Driving Terminal with AppleScript
would trigger a TCC automation prompt that can later be revoked, silently
breaking the icon's main job. Instead HerdrBar finds the `herdr` client process,
walks its parent chain to the GUI app that owns it, and calls
`NSRunningApplication.activate()`. No prompt, and it works with any terminal.

**The panel is one `session.snapshot` call.** Its `agents` array already carries
everything a row needs — `pane_id`, `workspace_id`, `tab_id`, `agent`,
`agent_status`, `terminal_title_stripped` and `focused` — so the panel keeps no
state of its own and cannot drift from what herdr believes. Selecting an agent is
`agent.focus` with its `pane_id`; that is the only target form herdr resolves (a
workspace label or a bare `claude` both come back `agent_not_found`), and it
falls back to `workspace.focus` if the agent exited between the snapshot and the
click.

**The panel is an `NSPanel`, not an `NSPopover`.** A popover insists on drawing
its own material and arrow around whatever it contains, which cannot produce a
flat dark surface with its own border. The panel is borderless and
non-activating, so it takes clicks and Escape without pulling HerdrBar forward.

**Waiting agents come from a plugin hook, not a socket subscription.**
`pane.agent_status_changed` requires a concrete `pane_id` under
`events.subscribe`, so there is no global form — but herdr's plugin hook
allowlist accepts it, which makes `[[events]]` the way to watch every pane at
once. Hook events only report blocked panes, though, while the badge also shows
`working` and `done` — so the app re-reads `session.snapshot` on a slow beat
(every twenty seconds, and coalesced after each event), and nothing goes stale if
the app was not running when an event fired.

## Troubleshooting

```bash
# What can the app see?
~/Applications/HerdrBar.app/Contents/MacOS/HerdrBar --diagnose

# Live state as JSON — including exactly the agents the panel would show
~/Applications/HerdrBar.app/Contents/MacOS/herdrbar-open --status

# Open the agents panel without clicking the icon
~/Applications/HerdrBar.app/Contents/MacOS/herdrbar-open --panel

# Did the hooks fire?
herdr plugin log list
```

To exercise the blink without waiting for a real agent, make herdr emit a
genuine status event against any pane:

```bash
herdr pane report-agent <PANE_ID> --source selftest --agent claude --state blocked
herdr pane report-agent <PANE_ID> --source selftest --agent claude --state idle
herdr pane release-agent <PANE_ID> --source selftest --agent claude
```

Use this rather than calling `scripts/forward-event.sh` with a hand-written
payload: herdr wraps event data in an `{"event":…,"data":{…}}` envelope, so a
flat hand-made payload tests a shape herdr never sends. Note also that
`herdr plugin log list` reporting `exit 0` does not prove delivery —
`forward-event.sh` always exits 0 so a hook can never stall herdr — check
`--status` instead.

`--diagnose` prints the resolved herdr binary, whether the server is up, which
terminal is hosting it, the open workspaces, the agents (with `▸` on the focused
one), and any waiting agents. If "host terminal: none" shows up while herdr is
clearly running, herdr is running without an attached client — start one and it
will resolve.

## Requirements

macOS 13 or later, herdr 0.8.0 or later, and the Swift compiler that ships with
Xcode or the Command Line Tools (for `scripts/build.sh`).

## License

MIT — see [LICENSE](LICENSE).

The licence covers the source code. It does not cover herdr's name or its ram
logo — see [NOTICE](NOTICE): `Resources/ram.svg` belongs to herdr and is
included only to identify the tool this plugin extends.
