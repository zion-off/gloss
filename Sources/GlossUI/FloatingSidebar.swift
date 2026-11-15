import AppKit
import SwiftUI
import GlossAppModel

/// What the sidebar shows, docked or floating: the source list, or the search results over it
/// while a search runs inside a book.
struct SidebarContent: View {
    let app: AppModel
    var revealToken = 0

    var body: some View {
        // The source list stays mounted under the results (hidden, not gone), so ending the
        // search puts the same sections, selection and scroll position back. No control switches
        // between them: ending the search is how the contents come back.
        ZStack(alignment: .topLeading) {
            SourceList(app: app, revealToken: revealToken)
                // Hidden, not removed, while the results cover it: a sidebar list is
                // translucent, so it must not draw through them, take clicks or be read by
                // VoiceOver — but it keeps its selection and scroll position.
                .opacity(app.search.showsResultsInSidebar ? 0 : 1)
                .allowsHitTesting(!app.search.showsResultsInSidebar)
                .accessibilityHidden(app.search.showsResultsInSidebar)
            if app.search.showsResultsInSidebar {
                SearchResults(app: app, placement: .sidebar)
            }
        }
    }
}

/// The undocked sidebar, over the detail column's leading edge: the panel, and a thin strip along
/// the edge that calls it. The panel is built once, when the sidebar undocks, and kept while it
/// stays undocked: floating in only slides it, so the source list (a book's whole contents) isn't
/// rebuilt on the slide's first frame. It slides in and out the way a sidebar does, over the
/// content, which never moves for it.
struct FloatingSidebar: View {
    let app: AppModel
    let docking: SidebarDocking
    let revealToken: Int
    /// The docked sidebar's width, which the floating one keeps.
    let width: CGFloat
    /// The pointer entered (true) or left a zone.
    let hover: (SidebarDocking.Zone, Bool) -> Void

    /// The panel's distance from the window's edges, and the edge strip's width.
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    static let shadowRadius: CGFloat = 12

    var body: some View {
        ZStack(alignment: .leading) {
            FloatingPanel(isShown: docking.isFloating, onHover: { hover(.panel, $0) }) {
                SidebarContent(app: app, revealToken: revealToken)
                    .scrollContentBackground(.hidden)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
            }
            .frame(width: width)
            .padding(Self.inset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("sidebar"))
            .accessibilityHidden(!docking.isFloating)
            // On top, so the strip gets the hover wherever it meets the panel's view.
            Color.clear
                .frame(width: Self.inset)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hover(.edge, $0) }
                .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .leading)
    }
}

/// The panel's view over the detail column, its frame where the panel shows. It holds the panel's
/// own hosting view, which slides out past the window's edge and back with a Core Animation frame
/// animation: the render server runs it, so work on the main thread can't make it stagger.
private struct FloatingPanel<Content: View>: NSViewRepresentable {
    let isShown: Bool
    let onHover: (Bool) -> Void
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> FloatingPanelContainer<Content> {
        let container = FloatingPanelContainer(panel: FloatingPanelHostingView(rootView: content))
        container.panel.onHover = onHover
        return container
    }

    func updateNSView(_ container: FloatingPanelContainer<Content>, context: Context) {
        container.panel.rootView = content
        container.panel.onHover = onHover
        container.setShown(isShown)
    }
}

private final class FloatingPanelContainer<Content: View>: NSView {
    let panel: FloatingPanelHostingView<Content>
    private var isShown = false
    /// Numbers each slide, so the end of an older one can't hide a panel that's back.
    private var slides = 0

    init(panel: FloatingPanelHostingView<Content>) {
        self.panel = panel
        super.init(frame: .zero)
        panel.isHidden = true
        addSubview(panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only the panel takes the pointer; the rest of this view lets it through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Where the panel rests while hidden: past the window's leading edge, shadow and all.
    private var hiddenFrame: NSRect {
        bounds.offsetBy(dx: -(bounds.width + frame.minX + 2 * FloatingSidebar.shadowRadius), dy: 0)
    }

    override func layout() {
        super.layout()
        panel.frame = isShown ? bounds : hiddenFrame
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            if panel.isHidden { panel.frame = hiddenFrame }
            panel.isHidden = false
        } else {
            panel.willHide()
        }
        slides += 1
        let slide = slides
        let target = shown ? bounds : hiddenFrame
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            panel.animator().frame = target
        }
        guard !shown else { return }
        // Out of VoiceOver and the key loop once it's off screen. A timer rather than the group's
        // completion handler, which a window that isn't drawing never calls.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, slide == self.slides, !self.isShown else { return }
            self.panel.isHidden = true
        }
    }
}

/// The panel's own hosting view, so the panel owns the pointer where it's drawn: the arrow over it,
/// and the book or notes underneath see neither its hovering nor its clicks. The shadow is a layer
/// shadow on the host, outside the clipped content.
private final class FloatingPanelHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var inside = false
    /// What had the keyboard focus before a click into the panel took it: it gets it back when
    /// the panel goes, rather than leaving the focus in a list that isn't there anymore.
    private weak var focusBeforePanel: NSResponder?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The shadow is set on every layout: the hosting view resets its layer's after init.
    override func layout() {
        super.layout()
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = FloatingSidebar.shadowRadius
        layer.shadowOffset = .zero  // all round, so a flipped layer can't send it the wrong way
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: FloatingSidebar.cornerRadius,
                                  cornerHeight: FloatingSidebar.cornerRadius, transform: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        // A panel that slides in under the pointer (search results arriving) gets no entered
        // event. After this layout pass, not during it: the hover changes the window's state.
        if let window, !isHidden, !inside, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            Task { @MainActor [weak self] in self?.pointer(inside: true) }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        pointer(inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        pointer(inside: false)
    }

    private func pointer(inside: Bool) {
        guard inside != self.inside else { return }
        self.inside = inside
        if inside, let responder = window?.firstResponder, !isInPanel(responder) { focusBeforePanel = responder }
        onHover?(inside)
    }

    /// The arrow over the whole panel, rows and gaps alike, like any sidebar.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// The panel is sliding away: the focus goes back to where it was before a click took it.
    func willHide() {
        guard let window, let responder = window.firstResponder, isInPanel(responder) else { return }
        let previous = (focusBeforePanel as? NSView).flatMap { $0.window === window ? $0 : nil }
        window.makeFirstResponder(previous)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            willHide()
            // Gone with the pointer still on it (docked from the keyboard): the panel no longer
            // holds the sidebar. After this update, not during it.
            if inside {
                inside = false
                let onHover = onHover
                Task { @MainActor in onHover?(false) }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func isInPanel(_ responder: NSResponder) -> Bool {
        (responder as? NSView)?.isDescendant(of: self) ?? false
    }
}

/// The docked sidebar: the sidebar's content in the system's sidebar material, a hairline, and a
/// grab area over the hairline that resizes it (the notes divider's, minus the line). gloss draws
/// it rather than using a split view's sidebar, whose own reveals (the full-screen edge, macOS 26's
/// peek) fought the floating one for the window's edge.
struct DockedSidebar<Content: View>: View {
    @Binding var width: Double
    @ViewBuilder let content: Content
    @State private var dragStart: Double?

    static var minWidth: Double { 180 }
    static var maxWidth: Double { 360 }

    var body: some View {
        HStack(spacing: 0) {
            content
                .scrollContentBackground(.hidden)
                .frame(width: width)
                .background(SidebarMaterial())
            Divider()
        }
        .overlay(alignment: .trailing) { grabArea }
    }

    /// Centred on the hairline, so it reaches a little into the content like a split view's.
    private var grabArea: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .offset(x: 3)
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? width
                    dragStart = start
                    width = min(max(start + drag.translation.width, Self.minWidth), Self.maxWidth)
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityHidden(true)
    }
}

/// The system's sidebar material, blended with what's behind the window, as a split view's
/// sidebar draws it.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
