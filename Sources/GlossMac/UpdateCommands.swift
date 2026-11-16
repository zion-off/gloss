#if os(macOS)
import AppKit
import Foundation
import Observation
import Sparkle
import SwiftUI
import GlossAppModel
import GlossUI

/// Sparkle's updater with gloss's own window (`UpdateFlow`, `UpdateView`) in place of Sparkle's
/// standard one: Sparkle still checks in the background (asking once, on the second launch),
/// downloads, verifies and installs. Only release bundles carry a feed and a public key
/// (scripts/release.sh). Without them (scripts/run-mac.sh, `swift run`) there is no updater at
/// all, so the menu item stays hidden, unless `GLOSS_UPDATE_PREVIEW` asks for the window with a
/// pretend update to look at (`UpdatePreview`).
@MainActor @Observable final class Updates {
    @ObservationIgnored let flow: UpdateFlow
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var driver: GlossUpdateDriver?
    @ObservationIgnored private var window: UpdateWindowController?
    @ObservationIgnored private var preview: UpdatePreview?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// Sparkle's `canCheckForUpdates`: false while a check is already running.
    private(set) var canCheck = false

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        flow = UpdateFlow(currentVersion: version)
        flow.openURL = { NSWorkspace.shared.open($0) }
        if Self.isConfigured(bundle) {
            window = UpdateWindowController(flow: flow)
            let driver = GlossUpdateDriver(flow: flow)
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
            do {
                try updater.start()
            } catch {
                // A release bundle whose feed or key Sparkle refuses: no updater, as in development.
                FileHandle.standardError.write(Data("gloss: the updater didn't start: \(error.localizedDescription)\n".utf8))
                return
            }
            self.driver = driver
            self.updater = updater
            // SPUUpdater is main-actor bound, so its changes arrive on the main thread.
            observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            }
        } else if let mode = environment["GLOSS_UPDATE_PREVIEW"] {
            window = UpdateWindowController(flow: flow)
            preview = UpdatePreview(flow: flow, mode: mode)
            canCheck = true
        }
    }

    var isAvailable: Bool { updater != nil || preview != nil }

    func check() {
        if let updater { updater.checkForUpdates() } else { preview?.check() }
    }

    private static func isConfigured(_ bundle: Bundle) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            (bundle.object(forInfoDictionaryKey: key) as? String).map { !$0.isEmpty } ?? false
        }
    }
}

/// Sparkle's user interface calls, passed on to the flow. Sparkle calls them on the main thread
/// and in order; the flow answers each reply once.
@MainActor final class GlossUpdateDriver: NSObject, SPUUserDriver {
    private let flow: UpdateFlow

    init(flow: UpdateFlow) {
        self.flow = flow
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        flow.showPermissionRequest { allowed in
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: allowed, sendSystemProfile: false))
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        flow.showChecking(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let notes = appcastItem.itemDescription.map { ReleaseNotes.blocks($0, format: appcastItem.itemDescriptionFormat) } ?? []
        let offer = UpdateFlow.Offer(version: appcastItem.displayVersionString, notes: notes,
                                     isDownloaded: state.stage != .notDownloaded,
                                     infoURL: appcastItem.isInformationOnlyUpdate ? appcastItem.infoURL : nil)
        flow.showUpdateFound(offer) { reply(Self.choice($0)) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let encoding = downloadData.textEncodingName
            .map { CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)) }
            .map { String.Encoding(rawValue: $0) } ?? .utf8
        guard let text = String(data: downloadData.data, encoding: encoding) ?? String(data: downloadData.data, encoding: .utf8) else { return }
        flow.showReleaseNotes(ReleaseNotes.blocks(text, format: downloadData.mimeType))
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // The offer stands without its notes.
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let newest = reason == nil || reason == .onLatestVersion || reason == .onNewerThanLatestVersion || reason == .unknown
        flow.showUpToDate(detail: newest ? nil : error.localizedDescription, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        flow.showFailure(error.localizedDescription, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        flow.showDownloadStarted(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        flow.showExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        flow.showReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        flow.showPreparing()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        flow.showPreparing(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        flow.showReadyToRelaunch { reply(Self.choice($0)) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        flow.showInstalling(applicationTerminated: applicationTerminated, retryTerminating: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // The new version is running: nothing to tell.
        acknowledgement()
    }

    func showUpdateInFocus() {
        flow.showInFocus()
    }

    func dismissUpdateInstallation() {
        flow.dismiss()
    }

    private static func choice(_ choice: UpdateFlow.Choice) -> SPUUserUpdateChoice {
        switch choice {
        case .install: .install
        case .later: .dismiss
        case .skip: .skip
        }
    }
}

/// The update window: a standard titled window, closable but not resizable, sized to its
/// content, shown and hidden as the flow says. It comes forward without taking focus from
/// another app (an update found by a background check waits for the user to come back).
@MainActor final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let flow: UpdateFlow
    private var window: NSWindow?

    init(flow: UpdateFlow) {
        self.flow = flow
        super.init()
        flow.onPresentationChange = { [weak self] presented in self?.show(presented) }
    }

    private func show(_ presented: Bool) {
        guard presented else {
            window?.orderOut(nil)
            return
        }
        let window = window ?? makeWindow()
        if NSApp.isActive { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: UpdateView(flow: flow))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "software update"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    /// The close button and ⌘W answer as the step's cancel button does; the flow hides the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        flow.close()
        return false
    }
}

/// A pretend update for looking at the window in a development build, which has no updater:
/// `open --env GLOSS_UPDATE_PREVIEW=available build/gloss.app`, then gloss › check for updates….
/// `available` offers an update with notes and runs a pretend download; `uptodate`, `error` and
/// `permission` show those steps. Nothing is downloaded or installed.
@MainActor final class UpdatePreview {
    private let flow: UpdateFlow
    private let mode: String
    private var task: Task<Void, Never>?

    init(flow: UpdateFlow, mode: String) {
        self.flow = flow
        self.mode = mode
    }

    func check() {
        task?.cancel()
        flow.showChecking { [weak self] in self?.task?.cancel() }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            switch mode {
            case "uptodate": flow.showUpToDate {}
            case "error": flow.showFailure("An error occurred while downloading the update. Please try again later.") {}
            case "permission": flow.showPermissionRequest { _ in }
            default: offer()
            }
        }
    }

    private func offer() {
        let notes = """
        - **spell check in your notes.** misspelled words get underlined as you type, and autocorrect follows your mac's setting.
        - **typing at the end of a page stays put**, however long the page.
        - **highlight with ⇧⌘H.** format › highlight marks the book's selection in the colour you used last.

        ## to try

        1. open a long page and type at the bottom.
        2. select a passage in a book and press ⇧⌘H.
        """
        let offer = UpdateFlow.Offer(version: "9.9", notes: ReleaseNotes.markdown(notes))
        flow.showUpdateFound(offer) { [weak self] choice in
            guard choice == .install else { return }
            self?.download()
        }
    }

    private func download() {
        task = Task { [weak self] in
            guard let self else { return }
            flow.showDownloadStarted { [weak self] in self?.task?.cancel() }
            flow.showExpectedLength(14_200_000)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(80))
                if Task.isCancelled { return }
                flow.showReceived(355_000)
            }
            flow.showPreparing()
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            // A real update relaunches here; the preview just ends.
            flow.showReadyToRelaunch { _ in }
            try? await Task.sleep(for: .seconds(1.5))
            flow.dismiss()
        }
    }
}

/// "check for updates…" in the app menu, beside "install command line tool".
struct GlossUpdateCommands: Commands {
    let updates: Updates

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            if updates.isAvailable {
                Button("check for updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        }
    }
}
#endif
