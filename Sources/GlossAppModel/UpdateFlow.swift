import Foundation
import Observation
import GlossMarkdown

/// The software update window: what it says and which buttons it offers at each step of an
/// update (asked to check automatically, checking, found, downloading, getting ready, ready to
/// relaunch, up to date, failed). The updater (Sparkle, in the app) drives it through the
/// `show…` methods and hands over its replies; the window renders the phase and runs `actions`.
/// Every reply is answered at most once, and a reply left over from an earlier step is dropped
/// when the next step arrives.
///
/// "update" goes straight through to the relaunch: the updater asks again once the download is
/// ready, and the flow answers for the user who already said yes. An update downloaded in the
/// background still asks.
@MainActor @Observable
public final class UpdateFlow {
    public struct Offer: Equatable, Sendable {
        public var version: String
        public var notes: [ReleaseNotes.Block]
        /// Already downloaded in the background: updating only relaunches.
        public var isDownloaded: Bool
        /// An announcement, not an installable update: "learn more" opens this.
        public var infoURL: URL?

        public init(version: String, notes: [ReleaseNotes.Block] = [], isDownloaded: Bool = false, infoURL: URL? = nil) {
            self.version = version
            self.notes = notes
            self.isDownloaded = isDownloaded
            self.infoURL = infoURL
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case askingPermission
        case checking
        case available(Offer)
        case downloading(Offer, received: UInt64, expected: UInt64?)
        case preparing(Offer, progress: Double?)
        case ready(Offer)
        case installing(Offer, quitRefused: Bool)
        case upToDate(detail: String?)
        case failed(String)
    }

    /// What the updater is told about an offer or a ready update.
    public enum Choice: Sendable {
        case install, later, skip
    }

    public enum Progress: Equatable, Sendable {
        case none, indeterminate
        case fraction(Double)
    }

    public struct Action: Identifiable, Equatable {
        /// `leading` sits apart at the far left (skip this version), `cancel` answers Escape and
        /// closing the window, `primary` is the default button (Return).
        public enum Role: Sendable { case leading, cancel, primary }
        public var id: String { title }
        public let title: String
        public let role: Role
        fileprivate let run: Run

        public static func == (a: Action, b: Action) -> Bool { a.title == b.title && a.role == b.role }
    }

    fileprivate enum Run: Equatable {
        case permission(Bool), choice(Choice), learnMore(URL), cancel, retryQuit, acknowledge
    }

    public let currentVersion: String
    public private(set) var phase: Phase = .idle
    /// Whether the window shows. Closing it during a step that runs on its own (getting ready,
    /// installing) only hides it; the next step that needs the user brings it back.
    public private(set) var isPresented = false {
        didSet { if isPresented != oldValue { onPresentationChange?(isPresented) } }
    }
    @ObservationIgnored public var onPresentationChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored public var openURL: (@MainActor (URL) -> Void)?

    @ObservationIgnored private var permissionReply: ((Bool) -> Void)?
    @ObservationIgnored private var choiceReply: ((Choice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?
    @ObservationIgnored private var retryQuitReply: (() -> Void)?
    /// The user chose "update" for the offer on screen: its "ready to relaunch" is answered for them.
    @ObservationIgnored private var installChosen = false

    public init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    // MARK: The updater's side

    public func showPermissionRequest(reply: @escaping (Bool) -> Void) {
        begin(.askingPermission)
        permissionReply = reply
        isPresented = true
    }

    public func showChecking(cancellation: @escaping () -> Void) {
        begin(.checking)
        self.cancellation = cancellation
        isPresented = true
    }

    public func showUpdateFound(_ offer: Offer, reply: @escaping (Choice) -> Void) {
        begin(.available(offer))
        installChosen = false
        choiceReply = reply
        isPresented = true
    }

    /// Release notes that arrived after the offer (downloaded from their own URL).
    public func showReleaseNotes(_ notes: [ReleaseNotes.Block]) {
        guard case .available(var offer) = phase else { return }
        offer.notes = notes
        phase = .available(offer)
    }

    public func showDownloadStarted(cancellation: @escaping () -> Void) {
        begin(.downloading(offer ?? Offer(version: ""), received: 0, expected: nil))
        self.cancellation = cancellation
    }

    public func showExpectedLength(_ length: UInt64) {
        guard case .downloading(let offer, let received, _) = phase else { return }
        phase = .downloading(offer, received: received, expected: length > 0 ? length : nil)
    }

    public func showReceived(_ length: UInt64) {
        guard case .downloading(let offer, let received, let expected) = phase else { return }
        phase = .downloading(offer, received: received + length, expected: expected)
    }

    public func showPreparing(progress: Double? = nil) {
        begin(.preparing(offer ?? Offer(version: ""), progress: progress.map { min(max($0, 0), 1) }))
    }

    public func showReadyToRelaunch(reply: @escaping (Choice) -> Void) {
        let offer = offer ?? Offer(version: "")
        if installChosen {
            begin(.installing(offer, quitRefused: false))
            reply(.install)
            return
        }
        begin(.ready(offer))
        choiceReply = reply
        isPresented = true
    }

    public func showInstalling(applicationTerminated: Bool, retryTerminating: @escaping () -> Void) {
        begin(.installing(offer ?? Offer(version: ""), quitRefused: !applicationTerminated))
        if !applicationTerminated {
            retryQuitReply = retryTerminating
            isPresented = true
        }
    }

    /// No update: `detail` says why when it isn't simply that this is the newest version.
    public func showUpToDate(detail: String? = nil, acknowledgement: @escaping () -> Void) {
        begin(.upToDate(detail: detail))
        self.acknowledgement = acknowledgement
        isPresented = true
    }

    public func showFailure(_ message: String, acknowledgement: @escaping () -> Void) {
        begin(.failed(message))
        self.acknowledgement = acknowledgement
        isPresented = true
    }

    public func showInFocus() {
        if phase != .idle { isPresented = true }
    }

    /// The updater is done with this update (or gave up): the window goes, unanswered replies
    /// are dropped (the updater no longer waits for them).
    public func dismiss() {
        begin(.idle)
        installChosen = false
        isPresented = false
    }

    // MARK: The window's side

    public var title: String {
        switch phase {
        case .idle: ""
        case .askingPermission: "check for updates automatically?"
        case .checking: "checking for updates…"
        case .available(let offer): "\(Self.name(offer)) is here"
        case .downloading(let offer, _, _): "downloading \(Self.name(offer))…"
        case .preparing(let offer, _): "getting \(Self.name(offer)) ready…"
        case .ready(let offer): "\(Self.name(offer)) is ready"
        case .installing(let offer, _): "installing \(Self.name(offer))…"
        case .upToDate: "you're up to date"
        case .failed: "couldn't update"
        }
    }

    public var detail: String? {
        switch phase {
        case .idle, .checking, .preparing: nil
        case .askingPermission:
            "gloss can look for new versions now and then, and asks before installing one. you can always check from the gloss menu."
        case .available(let offer):
            if offer.infoURL != nil { "you have \(currentVersion). this one is on the web." }
            else if offer.isDownloaded { "you have \(currentVersion). it's downloaded: updating relaunches gloss." }
            else { "you have \(currentVersion). updating relaunches gloss." }
        case .downloading(_, let received, let expected):
            expected.map { "\(Self.size(received)) of \(Self.size($0))" } ?? Self.size(received)
        case .ready: "relaunch now, or it installs the next time you quit."
        case .installing(_, let quitRefused): quitRefused ? "gloss didn't quit. close what's open and try again." : nil
        case .upToDate(let detail): detail ?? "gloss \(currentVersion) is the newest version."
        case .failed(let message): message
        }
    }

    public var progress: Progress {
        switch phase {
        case .checking, .installing: .indeterminate
        case .downloading(_, let received, let expected):
            expected.map { .fraction(min(Double(received) / Double($0), 1)) } ?? .indeterminate
        case .preparing(_, let progress): progress.map { .fraction($0) } ?? .indeterminate
        default: .none
        }
    }

    /// The notes of the offer on screen; nil when there is no offer or it has none.
    public var notes: [ReleaseNotes.Block]? {
        guard case .available(let offer) = phase, !offer.notes.isEmpty else { return nil }
        return offer.notes
    }

    public var actions: [Action] {
        switch phase {
        case .idle, .preparing: []
        case .askingPermission:
            [Action(title: "don't check", role: .cancel, run: .permission(false)),
             Action(title: "check automatically", role: .primary, run: .permission(true))]
        case .checking, .downloading: [Action(title: "cancel", role: .cancel, run: .cancel)]
        case .available(let offer):
            if let url = offer.infoURL {
                [Action(title: "skip this version", role: .leading, run: .choice(.skip)),
                 Action(title: "later", role: .cancel, run: .choice(.later)),
                 Action(title: "learn more", role: .primary, run: .learnMore(url))]
            } else {
                [Action(title: "skip this version", role: .leading, run: .choice(.skip)),
                 Action(title: "later", role: .cancel, run: .choice(.later)),
                 Action(title: "update", role: .primary, run: .choice(.install))]
            }
        case .ready:
            [Action(title: "later", role: .cancel, run: .choice(.later)),
             Action(title: "relaunch", role: .primary, run: .choice(.install))]
        case .installing(_, let quitRefused): quitRefused ? [Action(title: "try again", role: .primary, run: .retryQuit)] : []
        case .upToDate, .failed: [Action(title: "ok", role: .primary, run: .acknowledge)]
        }
    }

    public func perform(_ action: Action) {
        switch action.run {
        case .permission(let allowed):
            take(&permissionReply)?(allowed)
            dismiss()
        case .choice(let choice):
            guard let reply = take(&choiceReply) else { return }
            if choice == .install {
                installChosen = true
                // What follows comes from the updater; until it does, the step shows as begun.
                switch phase {
                case .available(let offer) where !offer.isDownloaded:
                    phase = .downloading(offer, received: 0, expected: nil)
                case .available(let offer), .ready(let offer):
                    phase = .installing(offer, quitRefused: false)
                default: break
                }
                reply(.install)
            } else {
                reply(choice)
                dismiss()
            }
        case .learnMore(let url):
            openURL?(url)
            take(&choiceReply)?(.later)
            dismiss()
        case .cancel:
            take(&cancellation)?()
            dismiss()
        case .retryQuit:
            take(&retryQuitReply)?()
        case .acknowledge:
            take(&acknowledgement)?()
            dismiss()
        }
    }

    /// The window's close button (and ⌘W): the step's cancel button when it has one, "ok" for an
    /// outcome; a step that runs on its own carries on with the window hidden.
    public func close() {
        if let cancel = actions.first(where: { $0.role == .cancel }) {
            perform(cancel)
        } else if let ok = actions.first(where: { $0.run == .acknowledge }) {
            perform(ok)
        } else {
            isPresented = false
        }
    }

    // MARK: Helpers

    private var offer: Offer? {
        switch phase {
        case .available(let offer), .ready(let offer): offer
        case .downloading(let offer, _, _), .preparing(let offer, _), .installing(let offer, _): offer
        default: nil
        }
    }

    /// A new step: the previous step's unanswered replies no longer apply.
    private func begin(_ next: Phase) {
        permissionReply = nil
        choiceReply = nil
        cancellation = nil
        acknowledgement = nil
        retryQuitReply = nil
        phase = next
    }

    private func take<T>(_ reply: inout T?) -> T? {
        defer { reply = nil }
        return reply
    }

    /// "gloss 1.5", or "the update" when the updater reached a step without saying which.
    private static func name(_ offer: Offer) -> String {
        offer.version.isEmpty ? "the update" : "gloss \(offer.version)"
    }

    /// Decimal sizes, as Finder shows them: "820 KB", "3.1 MB".
    static func size(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB", value / 1_000) }
        return "\(bytes) bytes"
    }
}

/// Release notes as the window draws them: headings, list items and paragraphs, each holding
/// inline markdown (bold, links, code) for the view to render. The appcast embeds the release
/// pull request's description as markdown; HTML and plain text are read too.
public enum ReleaseNotes {
    public enum Block: Hashable, Sendable {
        case heading(String)
        /// `marker`: "•" or the item's number ("2.").
        case item(marker: String, text: String, level: Int)
        case paragraph(String)
    }

    /// `format`: the appcast's `sparkle:format` (or a MIME type's subtype); nil reads as HTML,
    /// the appcast's default.
    public static func blocks(_ text: String, format: String?) -> [Block] {
        switch format?.lowercased() {
        case "markdown", "md", "text/markdown": markdown(text)
        case "plain", "text", "text/plain": plain(text)
        default: html(text)
        }
    }

    public static func markdown(_ source: String) -> [Block] {
        let document = MarkdownParser.standard.parse(source)
        var blocks: [Block] = []
        var paragraph: [String] = []
        var afterItem = false
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for block in document.blocks {
            let content = document.text[block.contentRange].trimmingCharacters(in: .whitespaces)
            switch block.kind {
            case .heading:
                flush()
                blocks.append(.heading(content))
                afterItem = false
            case .listItem:
                flush()
                let marker = block.attributes.ordered == true ? "\(block.attributes.number ?? 1)." : "•"
                blocks.append(.item(marker: marker, text: content, level: block.attributes.indent ?? 0))
                afterItem = true
            case .blank, .thematicBreak:
                flush()
                afterItem = false
            default:
                // A line straight under an item continues it (markdown's lazy continuation).
                if afterItem, case .item(let marker, let text, let level)? = blocks.last {
                    blocks[blocks.count - 1] = .item(marker: marker, text: text + " " + content, level: level)
                } else if !content.isEmpty {
                    paragraph.append(content)
                }
            }
        }
        flush()
        return blocks
    }

    public static func plain(_ text: String) -> [Block] {
        text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .map { .paragraph(escaped($0)) }
    }

    /// Enough HTML for release notes: headings, list items and paragraphs; other tags are dropped
    /// and the text kept.
    public static func html(_ source: String) -> [Block] {
        var blocks: [Block] = []
        let pattern = #"<(h[1-6]|li|p)\b[^>]*>(.*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        for match in regex.matches(in: source, range: range) {
            guard let tagRange = Range(match.range(at: 1), in: source), let bodyRange = Range(match.range(at: 2), in: source) else { continue }
            let tag = source[tagRange].lowercased()
            let text = escaped(stripTags(String(source[bodyRange])))
            guard !text.isEmpty else { continue }
            if tag.hasPrefix("h") {
                blocks.append(.heading(text))
            } else if tag == "li" {
                blocks.append(.item(marker: "•", text: text, level: 0))
            } else {
                blocks.append(.paragraph(text))
            }
        }
        if blocks.isEmpty { return plain(stripTags(source)) }
        return blocks
    }

    private static func stripTags(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Plain text carried as inline markdown: its own asterisks and brackets stay characters.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_`[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
