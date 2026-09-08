import AppKit
import Foundation

/// The single path every "open this project in herdr" entry point funnels
/// through — the folder picker, a recents row, Finder, and the CLI.
enum ProjectOpener {

    /// Resolve `path` to a directory (a file opens its parent), then hand it to
    /// herdr. Socket work happens off the main thread; AppKit calls hop back.
    static func open(path: String, config: Config, completion: (() -> Void)? = nil) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
            NSSound.beep()
            completion?()
            return
        }
        let directory = isDirectory.boolValue
            ? path
            : (path as NSString).deletingLastPathComponent

        DispatchQueue.global(qos: .userInitiated).async {
            let serverUp = HerdrClient.isRunning()
            var created = false
            if serverUp {
                created = HerdrClient.createWorkspace(
                    cwd: directory,
                    label: (directory as NSString).lastPathComponent)
            }

            DispatchQueue.main.async {
                if serverUp && created {
                    // The workspace exists and is focused; make sure something
                    // is actually displaying it.
                    if TerminalHost.hasVisibleClient() {
                        TerminalHost.bringToFront()
                    } else {
                        // Attaching with no cwd lands on the focused workspace.
                        TerminalHost.launchHerdr(cwd: nil, config: config)
                    }
                } else {
                    // No server (or the call failed): start herdr in the folder.
                    TerminalHost.launchHerdr(cwd: directory, config: config)
                }
                completion?()
            }
        }
    }

    /// Focus one agent and make sure it is on screen — the agents panel's row
    /// click, and the menu's waiting rows.
    ///
    /// `agent.focus` is the same operation as selecting the row inside herdr.
    /// It fails for a pane herdr no longer tracks as an agent (the agent
    /// exited between the snapshot and the click), so fall back to focusing the
    /// workspace, which at least lands the user in the right project.
    static func focusAgent(paneId: String, workspaceId: String, config: Config) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = HerdrClient.focusAgent(paneId: paneId)
                || HerdrClient.focusWorkspace(workspaceId)
            DispatchQueue.main.async {
                if TerminalHost.hasVisibleClient() {
                    TerminalHost.bringToFront()
                } else if ok {
                    TerminalHost.launchHerdr(cwd: nil, config: config)
                }
            }
        }
    }

    /// Focus a workspace and show it — the agents panel's workspace headers.
    static func focusWorkspace(_ workspaceId: String, config: Config) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = HerdrClient.focusWorkspace(workspaceId)
            DispatchQueue.main.async {
                if TerminalHost.hasVisibleClient() {
                    TerminalHost.bringToFront()
                } else if ok {
                    TerminalHost.launchHerdr(cwd: nil, config: config)
                }
            }
        }
    }

    /// Folder picker used by the menu and the `open-picker` plugin action.
    static func chooseFolder(config: Config) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open in herdr"
        panel.message = "Choose a folder to open as a herdr workspace"

        // An accessory-mode app has no windows, so the panel needs the app
        // pulled forward or it opens behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(path: url.path, config: config)
    }
}
