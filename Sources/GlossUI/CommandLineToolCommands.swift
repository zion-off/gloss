import AppKit
import SwiftUI
import GlossAppModel

/// The app menu's "install command line tool" / "remove command line tool": links the helper
/// inside gloss.app onto the PATH. `CommandLineTool` (GlossAppModel) decides the state and the
/// action; this is the AppKit half: the file operations, the admin password prompt when
/// `/usr/local/bin` needs one, and the alerts. Unlike the window commands this is one object for
/// the whole app (the menu item doesn't depend on which window is key); the app owns it.
@MainActor @Observable public final class CommandLineToolActions {
    @ObservationIgnored private var tool: CommandLineTool
    /// Bumped when the link may have changed, so the menu item re-reads it.
    private var revision = 0
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// - Parameter bundle: the running app; its `Contents/Helpers/gloss` is what gets linked.
    public init(bundle: Bundle = .main) {
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/gloss").path
        let available = FileManager.default.isExecutableFile(atPath: helper)
        tool = CommandLineTool(helperPath: available ? helper : nil)
        // The link can change behind our back (a terminal); look again when gloss comes forward.
        // The object lives as long as the app, so the observer never needs removing.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    public var menuTitle: String {
        _ = revision
        return tool.menuTitle
    }

    public var isEnabled: Bool {
        _ = revision
        return tool.isEnabled
    }

    /// Does what the menu item says, then reports.
    public func perform() {
        let action = tool.action
        switch action {
        case .none:
            return
        case .refuse(let why):
            show(title: "can't touch the command line tool", detail: why, style: .warning)
        case .install:
            Task { await run(action, done: "installed the command line tool",
                             detail: "done. open a new terminal and run gloss.",
                             failed: "couldn't install the command line tool") }
        case .remove:
            Task { await run(action, done: "removed the command line tool",
                             detail: "done. gloss is off your path.",
                             failed: "couldn't remove the command line tool") }
        }
    }

    private func run(_ action: CommandLineTool.Action, done: String, detail: String, failed: String) async {
        defer { revision += 1 }
        let outcome = await Task.detached(priority: .userInitiated) { Self.apply(action) }.value
        switch outcome {
        case .done: show(title: done, detail: detail, style: .informational)
        case .cancelled: break
        case .failed(let why): show(title: failed, detail: why, style: .warning)
        }
    }

    // MARK: Doing it

    private enum Outcome: Sendable {
        case done
        /// The user dismissed the password prompt: not an error, nothing to say.
        case cancelled
        case failed(String)
    }

    /// First as the user; only when that fails, through the system's admin prompt.
    private nonisolated static func apply(_ action: CommandLineTool.Action) -> Outcome {
        let unprivileged: any Error
        do {
            try applyAsUser(action)
            return .done
        } catch {
            unprivileged = error
        }
        guard let script = action.administratorAppleScript else { return .failed(unprivileged.localizedDescription) }
        return applyAsAdministrator(script)
    }

    private nonisolated static func applyAsUser(_ action: CommandLineTool.Action) throws {
        let files = FileManager.default
        switch action {
        case .install(let helper, let link, let replacing):
            try files.createDirectory(atPath: (link as NSString).deletingLastPathComponent,
                                      withIntermediateDirectories: true)
            // The decision already established the old link is ours to replace.
            if replacing { try files.removeItem(atPath: link) }
            try files.createSymbolicLink(atPath: link, withDestinationPath: helper)
        case .remove(let link):
            try files.removeItem(atPath: link)
        case .refuse, .none:
            break
        }
    }

    /// `osascript` shows the standard "gloss wants to make changes" password dialog. Its script
    /// goes as one argument, so there is no shell between us and it.
    private nonisolated static func applyAsAdministrator(_ script: String) -> Outcome {
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script]
        let errors = Pipe()
        osascript.standardError = errors
        osascript.standardOutput = FileHandle.nullDevice
        do {
            try osascript.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        // Read before waiting: a full pipe would block the child.
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        osascript.waitUntilExit()
        guard osascript.terminationStatus != 0 else { return .done }
        // AppleScript error -128: "User canceled."
        if message.contains("(-128)") { return .cancelled }
        return .failed(message.isEmpty ? "osascript exited with status \(osascript.terminationStatus)" : message)
    }

    private func show(title: String, detail: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "ok")
        alert.runModal()
    }
}

/// The app menu item, just after settings: a direct action, so no ellipsis.
public struct GlossCommandLineToolCommands: Commands {
    private let actions: CommandLineToolActions

    public init(actions: CommandLineToolActions) {
        self.actions = actions
    }

    public var body: some Commands {
        CommandGroup(after: .appSettings) {
            Divider()
            Button(actions.menuTitle) { actions.perform() }
                .disabled(!actions.isEnabled)
        }
    }
}
