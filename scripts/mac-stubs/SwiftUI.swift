// Stand-in for SwiftUI, for scripts/mac-typecheck.py (D-099). Declarations only, copied from
// Apple's documentation JSON (developer.apple.com/tutorials/data/documentation/swiftui/...).
//
// Where the newest docs spell a signature with SDK-internal machinery (`@ContentBuilder`,
// `EmptyContent`, `@export(implementation)`), this file uses the classic, source-compatible
// spelling that a macOS 14 deployment target compiles against (`@ViewBuilder`, `EmptyView`).
// Modifiers are `nonisolated` and views are `nonisolated struct`s, as the docs declare them;
// `View`, `App`, `Scene`, `Commands`, `ToolbarContent` and `NSViewRepresentable` are
// `@MainActor @preconcurrency` protocols. `@_disfavoredOverload` mirrors SwiftUI's overload
// ranking (a string literal is a `LocalizedStringKey`; a `String` value takes the
// `StringProtocol` overload). APIs deprecated in the newest SDK are marked deprecated here so
// the check flags them.

@_exported import AppKit
@_exported import Observation  // `import SwiftUI` brings @Observable along on Apple platforms
import UniformTypeIdentifiers

// MARK: - View and builders

/// swiftui/view — `@MainActor @preconcurrency protocol View`
@MainActor @preconcurrency public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency var body: Self.Body { get }
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

/// What every stub modifier returns, behind `some View`.
public struct _Modified<Content>: View {
    nonisolated public init(_ content: Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/viewbuilder
@resultBuilder public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> { TupleView((repeat each content)) }
    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildEither<TrueContent: View, FalseContent: View>(first: TrueContent) -> _ConditionalContent<TrueContent, FalseContent> { fatalError() }
    public static func buildEither<TrueContent: View, FalseContent: View>(second: FalseContent) -> _ConditionalContent<TrueContent, FalseContent> { fatalError() }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

nonisolated public struct TupleView<T>: View {
    public var value: T
    public init(_ value: T) { self.value = value }
    public var body: Never { fatalError() }
}

nonisolated public struct _ConditionalContent<TrueContent, FalseContent> {}
extension _ConditionalContent: View where TrueContent: View, FalseContent: View {
    public var body: Never { fatalError() }
}
extension _ConditionalContent: Commands where TrueContent: Commands, FalseContent: Commands {
    public var body: Never { fatalError() }
}
extension _ConditionalContent: ToolbarContent where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
    public var body: Never { fatalError() }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

/// swiftui/emptyview
nonisolated public struct EmptyView: View {
    public init() {}
    public var body: Never { fatalError() }
}

/// swiftui/anyview
nonisolated public struct AnyView: View {
    public init<V: View>(_ view: V) {}
    public init<V: View>(erasing view: V) {}
    public var body: Never { fatalError() }
}

/// swiftui/dynamicproperty
public protocol DynamicProperty {}

// MARK: - State and data flow

/// swiftui/state
@frozen @propertyWrapper public struct State<Value>: DynamicProperty {
    public init(wrappedValue value: Value) {}
    public init(initialValue value: Value) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
}
extension State where Value: ExpressibleByNilLiteral {
    public init() {}
}
extension State: Sendable where Value: Sendable {}

/// swiftui/scenestorage — `var wrappedValue: Value { get nonmutating set }`,
/// `var projectedValue: Binding<Value> { get }`; the initializers are overloads on one docs page
/// (`init(wrappedValue:_:)`, told apart by hash suffixes), only the ones gloss uses here.
@frozen @propertyWrapper public struct SceneStorage<Value>: DynamicProperty {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
    // In the body, not an extension: a property wrapper may not keep the implicit internal init().
    /// swiftui/scenestorage/init(wrappedValue:_:)-48yjd (macOS 11)
    public init(wrappedValue: Value, _ key: String) where Value == Bool {}
    /// swiftui/scenestorage/init(wrappedValue:_:)-3kgmn (macOS 11)
    public init(wrappedValue: Value, _ key: String) where Value == Int {}
    /// swiftui/scenestorage/init(wrappedValue:_:)-40fny (macOS 11)
    public init(wrappedValue: Value, _ key: String) where Value == String {}
    /// swiftui/scenestorage/init(wrappedValue:_:)-8hd2d (macOS 11)
    public init(wrappedValue: Value, _ key: String) where Value: RawRepresentable, Value.RawValue == String {}
}

/// swiftui/binding
@frozen @propertyWrapper @dynamicMemberLookup public struct Binding<Value> {
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {}
    public init(projectedValue: Binding<Value>) {}
    public static func constant(_ value: Value) -> Binding<Value> { fatalError() }
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { self }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> { fatalError() }
}
extension Binding: @unchecked Sendable where Value: Sendable {}

/// swiftui/bindable
@dynamicMemberLookup @propertyWrapper public struct Bindable<Value> {
    public init(wrappedValue: Value) where Value: AnyObject & Observable {}
    public init(_ wrappedValue: Value) where Value: AnyObject & Observable {}
    public var wrappedValue: Value { fatalError() }
    public var projectedValue: Bindable<Value> { self }
    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject> where Value: AnyObject { fatalError() }
}

/// swiftui/environment
@frozen @propertyWrapper public struct Environment<Value>: DynamicProperty {
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    public var wrappedValue: Value { fatalError() }
}

/// swiftui/environmentvalues
public struct EnvironmentValues {
    public init() {}
    /// swiftui/environmentvalues/undomanager
    public var undoManager: UndoManager? { nil }
    /// swiftui/environmentvalues/openwindow (macOS 13.0+)
    public var openWindow: OpenWindowAction { fatalError() }
    /// swiftui/environmentvalues/openurl
    public var openURL: OpenURLAction { fatalError() }
    /// swiftui/environmentvalues/dismiss
    public var dismiss: DismissAction { fatalError() }
    /// swiftui/environmentvalues/accessibilityreducemotion (macOS 10.15)
    public var accessibilityReduceMotion: Bool { false }
}

/// swiftui/openwindowaction — `@MainActor @preconcurrency struct OpenWindowAction`
@MainActor @preconcurrency public struct OpenWindowAction {
    public func callAsFunction(id: String) {}
    public func callAsFunction<D: Decodable & Encodable & Hashable>(value: D) {}
    public func callAsFunction<D: Decodable & Encodable & Hashable>(id: String, value: D) {}
}

/// swiftui/openurlaction
@MainActor @preconcurrency public struct OpenURLAction {
    public func callAsFunction(_ url: URL) {}
}

/// swiftui/dismissaction
@MainActor @preconcurrency public struct DismissAction {
    public func callAsFunction() {}
}

/// swiftui/focusedvalues
public struct FocusedValues {
    public init() {}
}

/// swiftui/focusedvalue
@propertyWrapper public struct FocusedValue<Value>: DynamicProperty {
    public init(_ keyPath: KeyPath<FocusedValues, Value?>) {}
    public var wrappedValue: Value? { nil }
}

/// swiftui/focusstate
@frozen @propertyWrapper public struct FocusState<Value: Hashable>: DynamicProperty {
    @frozen public struct Binding {
        public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
        public var projectedValue: FocusState<Value>.Binding { self }
    }
    public init() where Value == Bool {}
    public init<T: Hashable>() where Value == T? {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: FocusState<Value>.Binding { fatalError() }
}

// MARK: - Strings

/// swiftui/localizedstringkey
@frozen public struct LocalizedStringKey: Equatable, ExpressibleByStringInterpolation, Sendable {
    public init(_ value: String) {}
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation(_ string: String) {}
        public mutating func appendInterpolation(_ text: Text) {}
        public mutating func appendInterpolation(_ image: Image) {}
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T) {}
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T) {}
    }
}

// MARK: - Basic views

/// swiftui/text — `nonisolated struct Text`
nonisolated public struct Text: View, Equatable, Sendable {
    public init(_ key: LocalizedStringKey, tableName: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {}
    public init(verbatim content: String) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) {}
    public var body: Never { fatalError() }
    public func font(_ font: Font?) -> Text { self }
    public func bold() -> Text { self }
    public func italic() -> Text { self }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Text { self }
    public static func + (lhs: Text, rhs: Text) -> Text { lhs }
}

extension Text {
    /// swiftui/text/init(_:style:) (macOS 11.0+)
    public init(_ date: Date, style: Text.DateStyle) {}
}

/// swiftui/text/datestyle (macOS 11.0+)
extension Text {
    public struct DateStyle: Sendable {
        public static let date = Text.DateStyle(), time = Text.DateStyle()
        public static let relative = Text.DateStyle(), offset = Text.DateStyle(), timer = Text.DateStyle()
        init() {}
    }
}

/// swiftui/image
nonisolated public struct Image: View, Equatable, Sendable {
    public init(systemName: String) {}
    public init(nsImage: NSImage) {}
    public var body: Never { fatalError() }
    public func resizable() -> Image { self }
}

/// swiftui/label
nonisolated public struct Label<Title: View, Icon: View>: View {
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {}
    public var body: Never { fatalError() }
}
extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, systemImage name: String) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String) {}
}

/// swiftui/buttonrole
public struct ButtonRole: Equatable, Sendable {
    public static let destructive = ButtonRole()
    public static let cancel = ButtonRole()
}

/// swiftui/button — actions are `@MainActor` closures.
nonisolated public struct Button<Label: View>: View {
    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
    public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}
extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {}
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void) {}
}
extension Button where Label == SwiftUI.Label<Text, Image> {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, action: @escaping @MainActor () -> Void) {}
}

/// swiftui/toggle
nonisolated public struct Toggle<Label: View>: View {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}
extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {}
}

/// swiftui/picker
nonisolated public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}
extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
}

/// swiftui/foreach
nonisolated public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content> {}
extension ForEach: View where Content: View {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) where ID == Data.Element.ID, Data.Element: Identifiable {}
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) where Data == Range<Int>, ID == Int {}
    public var body: Never { fatalError() }
}

/// swiftui/hstack, vstack, zstack, group, spacer, divider
nonisolated public struct HStack<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
nonisolated public struct VStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
nonisolated public struct ZStack<Content: View>: View {
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
nonisolated public struct Group<Content> {}
extension Group: View where Content: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
nonisolated public struct Spacer: View {
    public init(minLength: CGFloat? = nil) {}
    public var body: Never { fatalError() }
}
nonisolated public struct Divider: View {
    public init() {}
    public var body: Never { fatalError() }
}

/// swiftui/axis
public enum Axis: Sendable {
    case horizontal, vertical
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1), vertical = Set(rawValue: 2)
    }
}

/// swiftui/scrollview
nonisolated public struct ScrollView<Content: View>: View {
    public init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/form (macOS 10.15+) — grouped rows on macOS by default.
nonisolated public struct Form<Content: View>: View {
    /// swiftui/form/init(content:)
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/slider (macOS 10.15+)
nonisolated public struct Slider<Label: View, ValueLabel: View>: View {
    public var body: Never { fatalError() }
}
extension Slider where Label == EmptyView, ValueLabel == EmptyView {
    /// swiftui/slider/init(value:in:step:oneditingchanged:)
    public init<V>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V : BinaryFloatingPoint, V.Stride : BinaryFloatingPoint {}
}
extension Slider {
    /// swiftui/slider/init(value:in:step:label:oneditingchanged:)
    public init<V>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V : BinaryFloatingPoint, V.Stride : BinaryFloatingPoint, ValueLabel == EmptyView {}
}

/// swiftui/stepper (macOS 10.15+)
nonisolated public struct Stepper<Label: View>: View {
    public var body: Never { fatalError() }
}
extension Stepper where Label == Text {
    /// swiftui/stepper/init(_:value:in:step:oneditingchanged:)-99t9q (macOS 13)
    public init<S: StringProtocol, V>(_ title: S, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V : Strideable {}
}

/// swiftui/labeledcontent (macOS 13.0+)
nonisolated public struct LabeledContent<Label, Content>: View {
    public var body: Never { fatalError() }
}
extension LabeledContent where Label == Text, Content: View {
    /// swiftui/labeledcontent/init(_:content:)-6g03w (macOS 13)
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}

/// swiftui/anytransition (macOS 10.15+)
@frozen public struct AnyTransition {
    /// swiftui/anytransition/opacity
    nonisolated(unsafe) public static let opacity: AnyTransition = AnyTransition()
    /// swiftui/anytransition/move(edge:)
    public static func move(edge: Edge) -> AnyTransition { AnyTransition() }
    /// swiftui/anytransition/combined(with:)
    public func combined(with other: AnyTransition) -> AnyTransition { self }
    init() {}
}

/// swiftui/animation (macOS 10.15+)
@frozen public struct Animation {
    /// swiftui/animation/snappy
    public static var snappy: Animation { Animation() }
    /// swiftui/animation/smooth (docs list macOS 10.15)
    public static var smooth: Animation { Animation() }
    /// swiftui/animation/default
    public static var `default`: Animation { Animation() }
    init() {}
}

/// swiftui/withanimation(_:_:) (macOS 10.15)
@MainActor public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result { try body() }

/// swiftui/list
nonisolated public struct List<SelectionValue: Hashable, Content: View>: View {
    public init(selection: Binding<SelectionValue?>?, @ViewBuilder content: () -> Content) {}
    public init(selection: Binding<Set<SelectionValue>>?, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
extension List where SelectionValue == Never {
    public init(@ViewBuilder content: () -> Content) {}
}

/// swiftui/section — `struct Section<Parent, Content, Footer>`, a `View` when all three are.
nonisolated public struct Section<Parent, Content, Footer> {}
extension Section: View where Parent: View, Content: View, Footer: View {
    public var body: Never { fatalError() }
}
extension Section where Parent == Text, Content: View, Footer == EmptyView {
    /// swiftui/section/init(_:content:) (macOS 12) — "Parent is Text and Footer is EmptyView"
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    /// swiftui/section/init(_:isExpanded:content:) (macOS 14)
    public init(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {}
}
extension Section where Parent: View, Content: View, Footer == EmptyView {
    /// swiftui/section/init(content:header:) (macOS 10.15)
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
    /// swiftui/section/init(isExpanded:content:header:) (macOS 14) — "Footer is EmptyView"
    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
}
extension Section where Parent: View, Content: View, Footer: View {
    /// swiftui/section/init(content:header:footer:) (macOS 10.15)
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {}
}
extension Section where Parent == EmptyView, Content: View, Footer == EmptyView {
    /// swiftui/section/init(content:) (macOS 10.15)
    public init(@ViewBuilder content: () -> Content) {}
}

/// swiftui/outlinegroup — `struct OutlineGroup<Data, ID, Parent, Leaf, Subgroup> where Data :
/// RandomAccessCollection, ID : Hashable`
nonisolated public struct OutlineGroup<Data: RandomAccessCollection, ID: Hashable, Parent, Leaf, Subgroup> {}
extension OutlineGroup: View where Parent: View, Leaf: View, Subgroup: View {
    public var body: Never { fatalError() }
}
/// "Data conforms to RandomAccessCollection, ID is Data.Element.ID, Parent conforms to View,
/// Parent is Leaf, Subgroup is DisclosureGroup<Parent, OutlineSubgroupChildren>, and
/// Data.Element conforms to Identifiable."
extension OutlineGroup where Data.Element: Identifiable, ID == Data.Element.ID, Parent: View, Parent == Leaf,
                             Subgroup == DisclosureGroup<Parent, OutlineSubgroupChildren> {
    /// swiftui/outlinegroup/init(_:children:content:)-4rmem (macOS 11)
    public init<DataElement>(_ data: Data, children: KeyPath<DataElement, Data?>, @ViewBuilder content: @escaping (DataElement) -> Leaf)
        where ID == DataElement.ID, DataElement: Identifiable, DataElement == Data.Element {}
}
/// swiftui/outlinesubgroupchildren
nonisolated public struct OutlineSubgroupChildren: View {
    public var body: Never { fatalError() }
}
/// swiftui/disclosuregroup — `struct DisclosureGroup<Label, Content> where Label : View, Content : View`
nonisolated public struct DisclosureGroup<Label: View, Content: View>: View {
    /// swiftui/disclosuregroup/init(content:label:) (macOS 11)
    public init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {}
    /// swiftui/disclosuregroup/init(isExpanded:content:label:) (macOS 11)
    public init(isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}

/// swiftui/geometryreader, geometryproxy
nonisolated public struct GeometryReader<Content: View>: View {
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {}
    public var body: Never { fatalError() }
}
public struct GeometryProxy {
    public var size: CGSize { .zero }
}

/// swiftui/contentunavailableview (macOS 14.0+)
nonisolated public struct ContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    public init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description = { EmptyView() }, @ViewBuilder actions: () -> Actions = { EmptyView() }) {}
    public var body: Never { fatalError() }
}
extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    public init(_ title: LocalizedStringKey, systemImage name: String, description: Text? = nil) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String, description: Text? = nil) {}
}

/// swiftui/progressview
nonisolated public struct ProgressView<Label: View, CurrentValueLabel: View>: View {
    public var body: Never { fatalError() }
}
extension ProgressView where Label == EmptyView, CurrentValueLabel == EmptyView {
    public init() {}
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) {}
}
extension ProgressView where CurrentValueLabel == EmptyView, Label == Text {
    public init(_ titleKey: LocalizedStringKey) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S) {}
}

/// swiftui/navigationsplitview (macOS 13.0+)
nonisolated public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View>: View {
    public var body: Never { fatalError() }
}
extension NavigationSplitView where Content == EmptyView {
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {}
    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {}
}
public struct NavigationSplitViewVisibility: Equatable, Codable, Sendable {
    public static var automatic: NavigationSplitViewVisibility { .init() }
    public static var all: NavigationSplitViewVisibility { .init() }
    public static var doubleColumn: NavigationSplitViewVisibility { .init() }
    public static var detailOnly: NavigationSplitViewVisibility { .init() }
}

/// swiftui/hsplitview (macOS-only)
nonisolated public struct HSplitView<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/controlgroup (macOS 12.0+)
nonisolated public struct ControlGroup<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/lazyvgrid — `nonisolated struct LazyVGrid<Content> where Content : View`
nonisolated public struct LazyVGrid<Content: View>: View {
    /// swiftui/lazyvgrid/init(columns:alignment:spacing:pinnedviews:content:) (macOS 11)
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/griditem — `struct GridItem : Sendable`
public struct GridItem: Sendable {
    /// swiftui/griditem/init(_:spacing:alignment:) (macOS 11)
    public init(_ size: GridItem.Size = .flexible(minimum: 10), spacing: CGFloat? = nil, alignment: Alignment? = nil) {}
    /// swiftui/griditem/size-swift.property (macOS 11)
    public var size: GridItem.Size { .flexible() }
    /// swiftui/griditem/size-swift.enum (macOS 11); adaptive's default is verified, the rest
    /// are declared without defaults the docs don't spell out.
    public enum Size: Sendable {
        /// swiftui/griditem/size-swift.enum/adaptive(minimum:maximum:) (macOS 11)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
        /// swiftui/griditem/size-swift.enum/fixed(_:) (macOS 11)
        case fixed(CGFloat)
        /// swiftui/griditem/size-swift.enum/flexible(minimum:maximum:) (macOS 11)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
    }
}

/// swiftui/pinnedscrollableviews (macOS 11)
public struct PinnedScrollableViews: Sendable {
    public init() {}
    /// swiftui/pinnedscrollableviews/sectionheaders
    public static let sectionHeaders = PinnedScrollableViews()
    /// swiftui/pinnedscrollableviews/sectionfooters
    public static let sectionFooters = PinnedScrollableViews()
}

/// swiftui/menu — `nonisolated struct Menu<Label, Content> where Label : View, Content : View`
nonisolated public struct Menu<Label: View, Content: View>: View {
    /// swiftui/menu/init(content:label:) (macOS 11)
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}
extension Menu where Label == Text {
    /// swiftui/menu/init(_:content:)-7v768 (macOS 11)
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    /// swiftui/menu/init(_:content:)-7tkrw (macOS 11)
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}

/// swiftui/textfield — `nonisolated struct TextField<Label> where Label : View`
nonisolated public struct TextField<Label: View>: View {
    public var body: Never { fatalError() }
}
extension TextField where Label == Text {
    /// swiftui/textfield/init(_:text:) (macOS 10.15)
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    /// swiftui/textfield/init(_:text:)-2laoi (macOS 10.15)
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    /// swiftui/textfield/init(_:text:axis:)-7n1bm (macOS 13.0)
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) {}
}

// MARK: - Shapes, colours, styles

/// swiftui/shapestyle
public protocol ShapeStyle: Sendable {}

/// swiftui/color
nonisolated public struct Color: View, ShapeStyle, Hashable {
    public init(nsColor: NSColor) {}
    public var body: Never { fatalError() }
    public func opacity(_ opacity: Double) -> Color { self }
    /// swiftui/color/init(_:red:green:blue:opacity:) (macOS 10.15)
    public init(_ colorSpace: Color.RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    /// swiftui/color/rgbcolorspace (macOS 10.15)
    public enum RGBColorSpace: Sendable { case sRGB, sRGBLinear, displayP3 }
    public static let clear = Color(), black = Color(), white = Color(), gray = Color(), red = Color()
    public static let orange = Color(), yellow = Color(), green = Color(), mint = Color(), teal = Color()
    public static let cyan = Color(), blue = Color(), indigo = Color(), purple = Color(), pink = Color()
    public static let brown = Color(), primary = Color(), secondary = Color()
    public static var accentColor: Color { Color() }
    private init() {}
}
extension ShapeStyle where Self == Color {
    public static var red: Color { .red }
    public static var yellow: Color { .yellow }
    public static var green: Color { .green }
    public static var blue: Color { .blue }
    public static var clear: Color { .clear }
    public static var accentColor: Color { .accentColor }
}

/// swiftui/anyshapestyle
public struct AnyShapeStyle: ShapeStyle {
    public init<S: ShapeStyle>(_ style: S) {}
}

/// swiftui/hierarchicalshapestyle
public struct HierarchicalShapeStyle: ShapeStyle {}
extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { .init() }
    public static var secondary: HierarchicalShapeStyle { .init() }
    public static var tertiary: HierarchicalShapeStyle { .init() }
    public static var quaternary: HierarchicalShapeStyle { .init() }
}

/// swiftui/material
public struct Material: ShapeStyle {}
extension ShapeStyle where Self == Material {
    public static var regularMaterial: Material { .init() }
    public static var thickMaterial: Material { .init() }
    public static var thinMaterial: Material { .init() }
    public static var ultraThinMaterial: Material { .init() }
    public static var bar: Material { .init() }
}

/// swiftui/backgroundstyle
public struct BackgroundStyle: ShapeStyle {}
extension ShapeStyle where Self == BackgroundStyle {
    public static var background: BackgroundStyle { .init() }
}

/// swiftui/foregroundstyle
public struct ForegroundStyle: ShapeStyle {}
extension ShapeStyle where Self == ForegroundStyle {
    public static var foreground: ForegroundStyle { .init() }
}

/// swiftui/tintshapestyle
public struct TintShapeStyle: ShapeStyle {}
extension ShapeStyle where Self == TintShapeStyle {
    public static var tint: TintShapeStyle { .init() }
}

/// swiftui/fillstyle
public struct FillStyle: Equatable, Sendable {
    public init(eoFill: Bool = false, antialiased: Bool = true) {}
}

/// swiftui/shape
public protocol Shape: View, Sendable {}
/// swiftui/insettableshape
public protocol InsettableShape: Shape {}

extension Shape {
    /// swiftui/shape/fill(_:style:)
    nonisolated public func fill<S: ShapeStyle>(_ content: S = .foreground, style: FillStyle = FillStyle()) -> some View { _Modified(self) }
    /// swiftui/shape/stroke(_:linewidth:)
    nonisolated public func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1) -> some View { _Modified(self) }
}
extension InsettableShape {
    /// swiftui/insettableshape/strokeborder(_:linewidth:antialiased:)
    nonisolated public func strokeBorder<S: ShapeStyle>(_ content: S = .foreground, lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View { _Modified(self) }
}

nonisolated public struct Circle: InsettableShape {
    public init() {}
    public var body: Never { fatalError() }
}
nonisolated public struct Rectangle: InsettableShape {
    public init() {}
    public var body: Never { fatalError() }
}
nonisolated public struct Capsule: InsettableShape {
    public init() {}
    public var body: Never { fatalError() }
}
public enum RoundedCornerStyle: Sendable { case circular, continuous }
nonisolated public struct RoundedRectangle: InsettableShape {
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {}
    public var body: Never { fatalError() }
}

/// swiftui/font
public struct Font: Hashable, Sendable {
    public struct Weight: Hashable, Sendable {
        public static let ultraLight = Weight(), thin = Weight(), light = Weight(), regular = Weight()
        public static let medium = Weight(), semibold = Weight(), bold = Weight(), heavy = Weight(), black = Weight()
    }
    public enum Design: Hashable, Sendable { case `default`, serif, rounded, monospaced }
    public static let largeTitle = Font(), title = Font(), title2 = Font(), title3 = Font(), headline = Font()
    public static let subheadline = Font(), body = Font(), callout = Font(), footnote = Font(), caption = Font(), caption2 = Font()
    public static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font { Font() }
    public func weight(_ weight: Font.Weight) -> Font { self }
    public func bold() -> Font { self }
    public func italic() -> Font { self }
    public func monospacedDigit() -> Font { self }
}

// MARK: - Layout values

public struct HorizontalAlignment: Equatable, Sendable {
    public static let leading = HorizontalAlignment(), center = HorizontalAlignment(), trailing = HorizontalAlignment()
}
public struct VerticalAlignment: Equatable, Sendable {
    public static let top = VerticalAlignment(), center = VerticalAlignment(), bottom = VerticalAlignment()
    public static let firstTextBaseline = VerticalAlignment(), lastTextBaseline = VerticalAlignment()
}
public struct Alignment: Equatable, Sendable {
    public static let center = Alignment(), leading = Alignment(), trailing = Alignment(), top = Alignment()
    public static let bottom = Alignment(), topLeading = Alignment(), topTrailing = Alignment()
    public static let bottomLeading = Alignment(), bottomTrailing = Alignment()
}
public enum Edge: Int8, CaseIterable, Sendable {
    case top, leading, bottom, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), leading = Set(rawValue: 2), bottom = Set(rawValue: 4), trailing = Set(rawValue: 8)
        public static let all = Set(rawValue: 15), horizontal = Set(rawValue: 10), vertical = Set(rawValue: 5)
    }
}
public struct EdgeInsets: Equatable, Sendable {
    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {}
}
public struct UnitPoint: Hashable, Sendable {
    public static let zero = UnitPoint(), center = UnitPoint(), top = UnitPoint(), bottom = UnitPoint()
}

/// swiftui/anchor/source
public struct Anchor<Value> {
    public struct Source {}
}
extension Anchor.Source where Value == CGRect {
    public static func rect(_ r: CGRect) -> Anchor<CGRect>.Source { .init() }
    public static var bounds: Anchor<CGRect>.Source { .init() }
}

/// swiftui/popoverattachmentanchor
public enum PopoverAttachmentAnchor {
    case rect(Anchor<CGRect>.Source)
    case point(UnitPoint)
}

/// swiftui/accessibilitytraits
public struct AccessibilityTraits: SetAlgebra, Sendable {
    public static let isButton = AccessibilityTraits(), isHeader = AccessibilityTraits(), isSelected = AccessibilityTraits()
    public static let isLink = AccessibilityTraits(), isImage = AccessibilityTraits(), isStaticText = AccessibilityTraits()
    public init() {}
    public func contains(_ member: AccessibilityTraits) -> Bool { false }
    public func union(_ other: AccessibilityTraits) -> AccessibilityTraits { self }
    public func intersection(_ other: AccessibilityTraits) -> AccessibilityTraits { self }
    public func symmetricDifference(_ other: AccessibilityTraits) -> AccessibilityTraits { self }
    public mutating func insert(_ newMember: AccessibilityTraits) -> (inserted: Bool, memberAfterInsert: AccessibilityTraits) { (false, self) }
    public mutating func remove(_ member: AccessibilityTraits) -> AccessibilityTraits? { nil }
    public mutating func update(with newMember: AccessibilityTraits) -> AccessibilityTraits? { nil }
    public mutating func formUnion(_ other: AccessibilityTraits) {}
    public mutating func formIntersection(_ other: AccessibilityTraits) {}
    public mutating func formSymmetricDifference(_ other: AccessibilityTraits) {}
}

// MARK: - Styles

public protocol PrimitiveButtonStyle {}
public protocol ButtonStyle {}
public struct BorderlessButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct PlainButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct LinkButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct BorderedButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct DefaultButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct AccessoryBarButtonStyle: PrimitiveButtonStyle { public init() {} }
extension PrimitiveButtonStyle where Self == BorderlessButtonStyle { public static var borderless: BorderlessButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == PlainButtonStyle { public static var plain: PlainButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == LinkButtonStyle { public static var link: LinkButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == BorderedButtonStyle { public static var bordered: BorderedButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { public static var borderedProminent: BorderedProminentButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == DefaultButtonStyle { public static var automatic: DefaultButtonStyle { .init() } }
/// macOS 14.0+
extension PrimitiveButtonStyle where Self == AccessoryBarButtonStyle { public static var accessoryBar: AccessoryBarButtonStyle { .init() } }

/// swiftui/controlgroupstyle; controlgroupstyle/navigation — `NavigationControlGroupStyle` (macOS 12.0)
public protocol ControlGroupStyle {}
public struct NavigationControlGroupStyle: ControlGroupStyle { public init() {} }
extension ControlGroupStyle where Self == NavigationControlGroupStyle { @MainActor public static var navigation: NavigationControlGroupStyle { .init() } }

/// swiftui/progressviewstyle; progressviewstyle/circular — `CircularProgressViewStyle` (macOS 11.0)
public protocol ProgressViewStyle {}
public struct CircularProgressViewStyle: ProgressViewStyle { public init() {} }
extension ProgressViewStyle where Self == CircularProgressViewStyle { public static var circular: CircularProgressViewStyle { .init() } }

/// swiftui/formstyle; swiftui/groupedformstyle, formstyle/grouped (macOS 13.0)
public protocol FormStyle {}
public struct GroupedFormStyle: FormStyle { public init() {} }
extension FormStyle where Self == GroupedFormStyle { public static var grouped: GroupedFormStyle { .init() } }

public protocol PickerStyle {}
public struct SegmentedPickerStyle: PickerStyle { public init() {} }
public struct MenuPickerStyle: PickerStyle { public init() {} }
public struct InlinePickerStyle: PickerStyle { public init() {} }
public struct RadioGroupPickerStyle: PickerStyle { public init() {} }
extension PickerStyle where Self == SegmentedPickerStyle { public static var segmented: SegmentedPickerStyle { .init() } }
extension PickerStyle where Self == MenuPickerStyle { public static var menu: MenuPickerStyle { .init() } }
extension PickerStyle where Self == InlinePickerStyle { public static var inline: InlinePickerStyle { .init() } }
extension PickerStyle where Self == RadioGroupPickerStyle { public static var radioGroup: RadioGroupPickerStyle { .init() } }

/// swiftui/liststyle; swiftui/sidebarliststyle (`static var sidebar: SidebarListStyle`, macOS 10.15)
public protocol ListStyle {}
public struct SidebarListStyle: ListStyle { public init() {} }
extension ListStyle where Self == SidebarListStyle { public static var sidebar: SidebarListStyle { .init() } }

// MARK: - View modifiers (all `nonisolated`, per the docs)

extension View {
    // Identity and state
    nonisolated public func id<ID: Hashable>(_ id: ID) -> some View { _Modified(self) }
    nonisolated public func tag<V: Hashable>(_ tag: V, includeOptional: Bool = true) -> some View { _Modified(self) }
    nonisolated public func disabled(_ disabled: Bool) -> some View { _Modified(self) }
    nonisolated public func allowsHitTesting(_ enabled: Bool) -> some View { _Modified(self) }

    // Life cycle: swiftui/view/task(id:name:priority:file:line:_:) and friends. The SDK's
    // interface also marks the action `@_inheritActorContext` (like `Task.init`); the docs JSON
    // drops underscored attributes. It's why a task started in `body` runs on the main actor.
    nonisolated public func task<T: Equatable>(id value: T, name: String? = nil, priority: TaskPriority = .userInitiated, file: String = #fileID, line: Int = #line,
                                               @_inheritActorContext _ action: sending @escaping @isolated(any) () async -> Void) -> some View { _Modified(self) }
    nonisolated public func task(name: String? = nil, priority: TaskPriority = .userInitiated, file: String = #fileID, line: Int = #line,
                                 @_inheritActorContext _ action: sending @escaping @isolated(any) () async -> Void) -> some View { _Modified(self) }
    nonisolated public func onAppear(perform action: (() -> Void)? = nil) -> some View { _Modified(self) }
    nonisolated public func onDisappear(perform action: (() -> Void)? = nil) -> some View { _Modified(self) }
    nonisolated public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View { _Modified(self) }
    nonisolated public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View { _Modified(self) }

    // Layout
    nonisolated public func padding(_ insets: EdgeInsets) -> some View { _Modified(self) }
    nonisolated public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View { _Modified(self) }
    nonisolated public func padding(_ length: CGFloat) -> some View { _Modified(self) }
    nonisolated public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View { _Modified(self) }
    nonisolated public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
                                  idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View { _Modified(self) }
    nonisolated public func fixedSize(horizontal: Bool, vertical: Bool) -> some View { _Modified(self) }
    nonisolated public func fixedSize() -> some View { _Modified(self) }
    nonisolated public func position(x: CGFloat = 0, y: CGFloat = 0) -> some View { _Modified(self) }
    nonisolated public func position(_ position: CGPoint) -> some View { _Modified(self) }
    nonisolated public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View { _Modified(self) }
    nonisolated public func layoutPriority(_ value: Double) -> some View { _Modified(self) }
    /// swiftui/view/aspectratio(_:contentmode:) (macOS 10.15)
    nonisolated public func aspectRatio(_ aspectRatio: CGFloat?, contentMode: ContentMode) -> some View { _Modified(self) }
    /// swiftui/view/clipped(antialiased:) (macOS 10.15)
    nonisolated public func clipped(antialiased: Bool = false) -> some View { _Modified(self) }
    /// swiftui/view/scaledtofill() (macOS 10.15)
    nonisolated public func scaledToFill() -> some View { _Modified(self) }
    /// swiftui/view/controlsize(_:) (macOS 10.15)
    nonisolated public func controlSize(_ controlSize: ControlSize) -> some View { _Modified(self) }

    // Appearance
    nonisolated public func font(_ font: Font?) -> some View { _Modified(self) }
    nonisolated public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { _Modified(self) }
    nonisolated public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle>(_ primary: S1, _ secondary: S2) -> some View { _Modified(self) }
    nonisolated public func lineLimit(_ number: Int?) -> some View { _Modified(self) }
    /// view/linelimit(_:)-251ko (macOS 13.0)
    nonisolated public func lineLimit(_ limit: PartialRangeFrom<Int>) -> some View { _Modified(self) }
    nonisolated public func multilineTextAlignment(_ alignment: TextAlignment) -> some View { _Modified(self) }
    nonisolated public func opacity(_ opacity: Double) -> some View { _Modified(self) }
    nonisolated public func shadow(color: Color = .black, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View { _Modified(self) }
    nonisolated public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View { _Modified(self) }
    nonisolated public func contentShape<S: Shape>(_ shape: S, eoFill: Bool = false) -> some View { _Modified(self) }
    nonisolated public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View { _Modified(self) }
    nonisolated public func background<S: ShapeStyle, T: InsettableShape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View { _Modified(self) }
    nonisolated public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _Modified(self) }
    nonisolated public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _Modified(self) }
    nonisolated public func overlay<S: ShapeStyle, T: Shape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View { _Modified(self) }
    @available(*, deprecated, message: "deprecated in macOS 27.3: use overlay(alignment:content:)")
    nonisolated public func overlay<Overlay: View>(_ overlay: Overlay, alignment: Alignment = .center) -> some View { _Modified(self) }
    nonisolated public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View { _Modified(self) }
    nonisolated public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View { _Modified(self) }
    nonisolated public func pickerStyle<S: PickerStyle>(_ style: S) -> some View { _Modified(self) }
    /// view/controlgroupstyle(_:) (macOS 12.0)
    nonisolated public func controlGroupStyle<S: ControlGroupStyle>(_ style: S) -> some View { _Modified(self) }
    /// view/progressviewstyle(_:) (macOS 11.0)
    nonisolated public func progressViewStyle<S: ProgressViewStyle>(_ style: S) -> some View { _Modified(self) }
    /// view/formstyle(_:) (macOS 13.0)
    nonisolated public func formStyle<S: FormStyle>(_ style: S) -> some View { _Modified(self) }
    /// view/labelshidden() (macOS 10.15)
    nonisolated public func labelsHidden() -> some View { _Modified(self) }
    /// view/linespacing(_:) (macOS 10.15)
    nonisolated public func lineSpacing(_ lineSpacing: CGFloat) -> some View { _Modified(self) }
    nonisolated public func labelStyle<S: LabelStyle>(_ style: S) -> some View { _Modified(self) }
    /// swiftui/view/transition(_:)-5h5h0 — the AnyTransition overload (10.15+; the page's
    /// 14.0 availability belongs to the generic `Transition` form above it).
    nonisolated public func transition(_ t: AnyTransition) -> some View { _Modified(self) }
    /// swiftui/view/animation(_:value:) (macOS 10.15+)
    nonisolated public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { _Modified(self) }

    // Help and accessibility
    nonisolated public func help(_ textKey: LocalizedStringKey) -> some View { _Modified(self) }
    @_disfavoredOverload nonisolated public func help<S: StringProtocol>(_ text: S) -> some View { _Modified(self) }
    nonisolated public func help(_ text: Text) -> some View { _Modified(self) }
    nonisolated public func accessibilityLabel(_ label: Text) -> some View { _Modified(self) }
    nonisolated public func accessibilityLabel(_ labelKey: LocalizedStringKey) -> some View { _Modified(self) }
    @_disfavoredOverload nonisolated public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { _Modified(self) }
    nonisolated public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { _Modified(self) }
    nonisolated public func accessibilityHidden(_ hidden: Bool) -> some View { _Modified(self) }
    nonisolated public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { _Modified(self) }

    // Presentation
    nonisolated public func popover<Content: View>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge? = nil,
                                                   @ViewBuilder content: @escaping () -> Content) -> some View { _Modified(self) }
    nonisolated public func alert<A: View, M: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View { _Modified(self) }
    @_disfavoredOverload nonisolated public func alert<S: StringProtocol, A: View, M: View>(_ title: S, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View { _Modified(self) }
    nonisolated public func alert<A: View, M: View>(_ title: Text, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View { _Modified(self) }
    nonisolated public func alert<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A) -> some View { _Modified(self) }
    nonisolated public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View { _Modified(self) }
    nonisolated public func sheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View { _Modified(self) }
    nonisolated public func confirmationDialog<A: View, M: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic,
                                                                 @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View { _Modified(self) }

    // Navigation, toolbar, focus, commands
    nonisolated public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { _Modified(self) }
    @_disfavoredOverload nonisolated public func navigationTitle<S: StringProtocol>(_ title: S) -> some View { _Modified(self) }
    nonisolated public func navigationTitle(_ title: Text) -> some View { _Modified(self) }
    nonisolated public func navigationSubtitle(_ subtitleKey: LocalizedStringKey) -> some View { _Modified(self) }
    @_disfavoredOverload nonisolated public func navigationSubtitle<S: StringProtocol>(_ subtitle: S) -> some View { _Modified(self) }
    nonisolated public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View { _Modified(self) }
    nonisolated public func toolbar<Content: ToolbarContent>(@ToolbarContentBuilder content: () -> Content) -> some View { _Modified(self) }
    nonisolated public func focusedSceneValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T) -> some View { _Modified(self) }
    nonisolated public func focusedSceneValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T?) -> some View { _Modified(self) }
    nonisolated public func focusedValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T?) -> some View { _Modified(self) }
    nonisolated public func focused(_ condition: FocusState<Bool>.Binding) -> some View { _Modified(self) }
    nonisolated public func focused<V: Hashable>(_ binding: FocusState<V>.Binding, equals value: V) -> some View { _Modified(self) }
    nonisolated public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View { _Modified(self) }
    nonisolated public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View { _Modified(self) }
    nonisolated public func onOpenURL(perform action: @escaping (URL) -> ()) -> some View { _Modified(self) }
    nonisolated public func handlesExternalEvents(preferring: Set<String>, allowing: Set<String>) -> some View { _Modified(self) }
    nonisolated public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool,
                                         onCompletion: @escaping (Result<[URL], any Error>) -> Void) -> some View { _Modified(self) }
    nonisolated public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringKey) -> some View { _Modified(self) }
    /// swiftui/view/searchable(text:ispresented:placement:prompt:) (macOS 14.0; prompt documented as
    /// LocalizedStringResource, kept LocalizedStringKey like the overload above)
    nonisolated public func searchable(text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringKey) -> some View { _Modified(self) }
    /// swiftui/view/searchscopes(_:activation:_:) (macOS 13.3)
    nonisolated public func searchScopes<V, S>(_ scope: Binding<V>, activation: SearchScopeActivation,
                                              @ViewBuilder _ scopes: () -> S) -> some View where V: Hashable, S: View { _Modified(self) }
    /// swiftui/view/onkeypress(keys:phases:action:) (macOS 14.0)
    nonisolated public func onKeyPress(keys: Set<KeyEquivalent>, phases: KeyPress.Phases = [.down, .repeat],
                                       action: @escaping (KeyPress) -> KeyPress.Result) -> some View { _Modified(self) }
    /// swiftui/view/onkeypress(_:phases:action:) (macOS 14.0)
    nonisolated public func onKeyPress(_ key: KeyEquivalent, phases: KeyPress.Phases = [.down, .repeat],
                                       action: @escaping (KeyPress) -> KeyPress.Result) -> some View { _Modified(self) }
    /// swiftui/view/textfieldstyle(_:) (macOS 12.0)
    nonisolated public func textFieldStyle<_Style: TextFieldStyle>(_ style: _Style) -> some View { _Modified(self) }
    /// swiftui/view/cornerradius(_:antialiased:) — the method form (macOS 10.15)
    nonisolated public func cornerRadius(_ radius: CGFloat, antialiased: Bool = true) -> some View { _Modified(self) }
    /// swiftui/view/ontapgesture(count:coordinateSpace:perform:) (macOS 10.15)
    nonisolated public func onTapGesture(count: Int = 1, coordinateSpace: CoordinateSpace = .local, perform action: @escaping () -> Void) -> some View { _Modified(self) }
    nonisolated public func inspector<V: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> V) -> some View { _Modified(self) }
    /// swiftui/view/liststyle(_:) (macOS 10.15)
    nonisolated public func listStyle<S: ListStyle>(_ style: S) -> some View { _Modified(self) }
    /// swiftui/view/badge(_:) overloads: -8adyq (Int, "set the value to zero to hide the badge"),
    /// -84e43 (LocalizedStringKey?), -6k2u9 (Text?), -6x46k (StringProtocol?) — macOS 12
    nonisolated public func badge(_ count: Int) -> some View { _Modified(self) }
    nonisolated public func badge(_ key: LocalizedStringKey?) -> some View { _Modified(self) }
    nonisolated public func badge(_ label: Text?) -> some View { _Modified(self) }
    @_disfavoredOverload nonisolated public func badge<S: StringProtocol>(_ label: S?) -> some View { _Modified(self) }
    /// swiftui/view/contextmenu(menuitems:) (macOS 10.15)
    nonisolated public func contextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View { _Modified(self) }
    /// swiftui/view/ondeletecommand(perform:) (macOS 10.15)
    nonisolated public func onDeleteCommand(perform action: (() -> Void)?) -> some View { _Modified(self) }
    /// swiftui/view/ondrop(of:istargeted:perform:) (macOS 11)
    nonisolated public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider]) -> Bool) -> some View { _Modified(self) }
    /// swiftui/view/navigationsplitviewcolumnwidth(min:ideal:max:) (macOS 13)
    nonisolated public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View { _Modified(self) }
}

public enum TextAlignment: Hashable, Sendable { case leading, center, trailing }
public enum Visibility: Hashable, Sendable { case automatic, visible, hidden }
/// swiftui/contentmode (macOS 10.15)
public enum ContentMode: Sendable { case fit, fill }
/// swiftui/controlsize (macOS 10.15)
public enum ControlSize: Sendable { case mini, small, regular, large }
public struct AccessibilityChildBehavior: Hashable, Sendable {
    public static let ignore = AccessibilityChildBehavior(), contain = AccessibilityChildBehavior(), combine = AccessibilityChildBehavior()
}
public protocol LabelStyle {}
public struct IconOnlyLabelStyle: LabelStyle { public init() {} }
public struct TitleOnlyLabelStyle: LabelStyle { public init() {} }
public struct TitleAndIconLabelStyle: LabelStyle { public init() {} }
extension LabelStyle where Self == IconOnlyLabelStyle { public static var iconOnly: IconOnlyLabelStyle { .init() } }
extension LabelStyle where Self == TitleOnlyLabelStyle { public static var titleOnly: TitleOnlyLabelStyle { .init() } }
extension LabelStyle where Self == TitleAndIconLabelStyle { public static var titleAndIcon: TitleAndIconLabelStyle { .init() } }
public struct SearchFieldPlacement: Sendable {
    public static let automatic = SearchFieldPlacement(), toolbar = SearchFieldPlacement(), sidebar = SearchFieldPlacement()
}

/// swiftui/searchscopeactivation (macOS 13.3) — `struct SearchScopeActivation`
public struct SearchScopeActivation: Sendable {
    /// swiftui/searchscopeactivation/automatic
    public static var automatic: SearchScopeActivation { .init() }
    /// swiftui/searchscopeactivation/onsearchpresentation
    public static var onSearchPresentation: SearchScopeActivation { .init() }
    /// swiftui/searchscopeactivation/ontextentry
    public static var onTextEntry: SearchScopeActivation { .init() }
    private init() {}
}

/// swiftui/keypress (macOS 14.0) — `struct KeyPress`
public struct KeyPress: Sendable {
    /// swiftui/keypress/key
    public let key: KeyEquivalent
    /// swiftui/keypress/characters
    public let characters: String
    /// swiftui/keypress/modifiers
    public let modifiers: EventModifiers
    /// swiftui/keypress/phase
    public let phase: KeyPress.Phase

    /// swiftui/keypress/result (macOS 14.0) — `enum Result`
    public enum Result: Sendable {
        /// swiftui/keypress/result/handled
        case handled
        /// swiftui/keypress/result/ignored
        case ignored
    }

    /// swiftui/keypress/phases (macOS 14.0) — `struct Phases`
    public struct Phases: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// swiftui/keypress/phases/down
        public static let down = Phases(rawValue: 1)
        /// swiftui/keypress/phases/up
        public static let up = Phases(rawValue: 2)
        /// swiftui/keypress/phases/repeat
        public static let `repeat` = Phases(rawValue: 4)
        /// swiftui/keypress/phases/all
        public static let all = Phases(rawValue: 7)
    }

    /// swiftui/keypress/phase
    public enum Phase: Sendable {
        case down, up, `repeat`
    }
}

/// swiftui/textfieldstyle — a protocol like the other style protocols.
public protocol TextFieldStyle {}
public struct PlainTextFieldStyle: TextFieldStyle { public init() {} }
public struct RoundedTextFieldStyle: TextFieldStyle { public init() {} }
extension TextFieldStyle where Self == PlainTextFieldStyle { public static var plain: PlainTextFieldStyle { .init() } }
extension TextFieldStyle where Self == RoundedTextFieldStyle { public static var rounded: RoundedTextFieldStyle { .init() } }


/// swiftui/coordinatespace
public enum CoordinateSpace: Hashable, Sendable {
    case local, global, named
}

// MARK: - Keyboard

/// swiftui/keyequivalent
public struct KeyEquivalent: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    public init(_ character: Character) {}
    public init(extendedGraphemeClusterLiteral: Character) {}
    public static let upArrow = KeyEquivalent(" "), downArrow = KeyEquivalent(" "), leftArrow = KeyEquivalent(" "), rightArrow = KeyEquivalent(" ")
    public static let escape = KeyEquivalent(" "), delete = KeyEquivalent(" "), deleteForward = KeyEquivalent(" ")
    public static let `return` = KeyEquivalent(" "), space = KeyEquivalent(" "), tab = KeyEquivalent(" ")
}

/// swiftui/eventmodifiers
public struct EventModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let capsLock = EventModifiers(rawValue: 1), shift = EventModifiers(rawValue: 2), control = EventModifiers(rawValue: 4)
    public static let option = EventModifiers(rawValue: 8), command = EventModifiers(rawValue: 16), numericPad = EventModifiers(rawValue: 32)
    public static let function = EventModifiers(rawValue: 64), all = EventModifiers(rawValue: 127)
}

/// swiftui/keyboardshortcut
public struct KeyboardShortcut: Hashable, Sendable {
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) {}
    public static let defaultAction = KeyboardShortcut(.return, modifiers: []), cancelAction = KeyboardShortcut(.escape, modifiers: [])
}

// MARK: - Toolbar

/// swiftui/toolbarcontent
@MainActor @preconcurrency public protocol ToolbarContent {
    associatedtype Body: ToolbarContent
    @ToolbarContentBuilder var body: Self.Body { get }
}
extension Never: ToolbarContent {}
extension Optional: ToolbarContent where Wrapped: ToolbarContent {
    public var body: Never { fatalError() }
}

nonisolated public struct _TupleToolbarContent<T>: ToolbarContent {
    public init(_ value: T) {}
    public var body: Never { fatalError() }
}

/// swiftui/toolbarcontentbuilder
@resultBuilder public struct ToolbarContentBuilder {
    public static func buildBlock<Content: ToolbarContent>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: ToolbarContent>(_ content: repeat each Content) -> _TupleToolbarContent<(repeat each Content)> { _TupleToolbarContent((repeat each content)) }
    public static func buildExpression<Content: ToolbarContent>(_ content: Content) -> Content { content }
    public static func buildIf<Content: ToolbarContent>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(first: T) -> _ConditionalContent<T, F> { fatalError() }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(second: F) -> _ConditionalContent<T, F> { fatalError() }
}

/// swiftui/toolbaritemplacement
public struct ToolbarItemPlacement: Sendable {
    public static let automatic = ToolbarItemPlacement(), navigation = ToolbarItemPlacement(), principal = ToolbarItemPlacement()
    public static let primaryAction = ToolbarItemPlacement(), secondaryAction = ToolbarItemPlacement(), status = ToolbarItemPlacement()
    public static let confirmationAction = ToolbarItemPlacement(), cancellationAction = ToolbarItemPlacement()
    public static let destructiveAction = ToolbarItemPlacement()
}

/// swiftui/toolbaritem
nonisolated public struct ToolbarItem<ID, Content: View>: ToolbarContent {
    public var body: Never { fatalError() }
}
extension ToolbarItem where ID == () {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {}
}

/// swiftui/defaulttoolbaritem; defaulttoolbaritem/init(kind:placement:) (macOS 26.0)
@available(macOS 26.0, *)
nonisolated public struct DefaultToolbarItem: ToolbarContent {
    public init(kind: ToolbarDefaultItemKind, placement: ToolbarItemPlacement = .automatic) {}
    public var body: Never { fatalError() }
}
/// swiftui/toolbardefaultitemkind/search (macOS 26.0)
@available(macOS 26.0, *)
public struct ToolbarDefaultItemKind: Sendable {
    public static let search = ToolbarDefaultItemKind()
}
@available(macOS 26.0, *)
extension ToolbarContent {
    /// swiftui/toolbarcontent/sharedbackgroundvisibility(_:) (macOS 26.0)
    nonisolated public func sharedBackgroundVisibility(_ visibility: Visibility) -> Self { self }
}

/// swiftui/toolbaritemgroup
nonisolated public struct ToolbarItemGroup<Content: View>: ToolbarContent {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

// MARK: - Commands

/// swiftui/commands
@MainActor @preconcurrency public protocol Commands {
    associatedtype Body: Commands
    @CommandsBuilder var body: Self.Body { get }
}
extension Never: Commands {}
extension Optional: Commands where Wrapped: Commands {
    public var body: Never { fatalError() }
}

nonisolated public struct EmptyCommands: Commands {
    public init() {}
    public var body: Never { fatalError() }
}
nonisolated public struct _TupleCommands<T>: Commands {
    public init(_ value: T) {}
    public var body: Never { fatalError() }
}

/// swiftui/commandsbuilder
@resultBuilder public struct CommandsBuilder {
    public static func buildBlock() -> EmptyCommands { EmptyCommands() }
    public static func buildBlock<Content: Commands>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: Commands>(_ content: repeat each Content) -> _TupleCommands<(repeat each Content)> { _TupleCommands((repeat each content)) }
    public static func buildExpression<Content: Commands>(_ content: Content) -> Content { content }
    public static func buildIf<Content: Commands>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: Commands, F: Commands>(first: T) -> _ConditionalContent<T, F> { fatalError() }
    public static func buildEither<T: Commands, F: Commands>(second: F) -> _ConditionalContent<T, F> { fatalError() }
}

/// swiftui/commandgroupplacement
public struct CommandGroupPlacement: Sendable {
    public static let appInfo = CommandGroupPlacement(), appSettings = CommandGroupPlacement(), systemServices = CommandGroupPlacement()
    public static let appVisibility = CommandGroupPlacement(), appTermination = CommandGroupPlacement()
    public static let newItem = CommandGroupPlacement(), saveItem = CommandGroupPlacement(), importExport = CommandGroupPlacement()
    public static let printItem = CommandGroupPlacement(), undoRedo = CommandGroupPlacement(), pasteboard = CommandGroupPlacement()
    public static let textEditing = CommandGroupPlacement(), textFormatting = CommandGroupPlacement(), toolbar = CommandGroupPlacement()
    public static let sidebar = CommandGroupPlacement(), windowSize = CommandGroupPlacement(), windowList = CommandGroupPlacement()
    public static let singleWindowList = CommandGroupPlacement(), windowArrangement = CommandGroupPlacement(), help = CommandGroupPlacement()
}

/// swiftui/commandgroup
nonisolated public struct CommandGroup<Content: View>: Commands {
    public init(before group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public init(after group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public init(replacing group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/commandmenu
nonisolated public struct CommandMenu<Content: View>: Commands {
    public init(_ nameKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ name: S, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

// MARK: - App and scenes

/// swiftui/app
@MainActor @preconcurrency public protocol App {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Self.Body { get }
    @MainActor @preconcurrency init()
}
extension App {
    @MainActor @preconcurrency public static func main() {}
}

/// swiftui/scene
@MainActor @preconcurrency public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Self.Body { get }
}
extension Never: Scene {}

nonisolated public struct _TupleScene<T>: Scene {
    public init(_ value: T) {}
    public var body: Never { fatalError() }
}
nonisolated public struct _ModifiedScene<Content>: Scene {
    public init(_ content: Content) {}
    public var body: Never { fatalError() }
}

/// swiftui/scenebuilder
@resultBuilder public struct SceneBuilder {
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: Scene>(_ content: repeat each Content) -> _TupleScene<(repeat each Content)> { _TupleScene((repeat each content)) }
    public static func buildExpression<Content: Scene>(_ content: Content) -> Content { content }
}

extension Scene {
    nonisolated public func commands<Content: Commands>(@CommandsBuilder content: () -> Content) -> some Scene { _ModifiedScene(self) }
    nonisolated public func defaultSize(width: CGFloat, height: CGFloat) -> some Scene { _ModifiedScene(self) }
    nonisolated public func handlesExternalEvents(matching conditions: Set<String>) -> some Scene { _ModifiedScene(self) }
}

/// swiftui/windowgroup
nonisolated public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
    /// swiftui/windowgroup/init(id:makecontent:) (macOS 11.0+) — `init(id:content:)` is
    /// deprecated from macOS 15 in favour of this one; same call shape, so only this is stubbed.
    public init(id: String, @ViewBuilder makeContent: @escaping () -> Content) {}
    public var body: Never { fatalError() }
}
/// swiftui/presentedwindowcontent
nonisolated public struct PresentedWindowContent<Data, Content>: View {
    public var body: Never { fatalError() }
}
extension WindowGroup {
    /// swiftui/windowgroup/init(for:content:) — macOS 13.0+
    public init<D: Decodable & Encodable & Hashable, C: View>(for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> C) where Content == PresentedWindowContent<D, C> {}
    public init<D: Decodable & Encodable & Hashable, C: View>(id: String, for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> C) where Content == PresentedWindowContent<D, C> {}
}

/// swiftui/settings (macOS-only)
nonisolated public struct Settings<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

// MARK: - AppKit interop

/// swiftui/nsviewrepresentable — `@MainActor @preconcurrency protocol NSViewRepresentable : View where Self.Body == Never`
@MainActor @preconcurrency public protocol NSViewRepresentable: View where Self.Body == Never {
    associatedtype NSViewType: NSView
    associatedtype Coordinator = Void
    typealias Context = NSViewRepresentableContext<Self>
    @MainActor @preconcurrency func makeNSView(context: Self.Context) -> Self.NSViewType
    @MainActor @preconcurrency func updateNSView(_ nsView: Self.NSViewType, context: Self.Context)
    @MainActor @preconcurrency static func dismantleNSView(_ nsView: Self.NSViewType, coordinator: Self.Coordinator)
    @MainActor @preconcurrency func makeCoordinator() -> Self.Coordinator
}
extension NSViewRepresentable {
    @MainActor @preconcurrency public static func dismantleNSView(_ nsView: Self.NSViewType, coordinator: Self.Coordinator) {}
    public var body: Never { fatalError() }
}
extension NSViewRepresentable where Self.Coordinator == Void {
    @MainActor @preconcurrency public func makeCoordinator() -> Void {}
}

/// swiftui/nsviewrepresentablecontext
@MainActor @preconcurrency public struct NSViewRepresentableContext<Representable: NSViewRepresentable> {
    @MainActor @preconcurrency public let coordinator: Representable.Coordinator
    public var environment: EnvironmentValues { EnvironmentValues() }
}

/// swiftui/nshostingcontroller — `@MainActor @preconcurrency init(rootView:)`
@MainActor @preconcurrency open class NSHostingController<Content: View>: NSViewController {
    @MainActor @preconcurrency public init(rootView: Content) { super.init() }
    public var rootView: Content { get { fatalError() } set {} }
}

/// swiftui/nshostingview
@MainActor @preconcurrency open class NSHostingView<Content: View>: NSView {
    @MainActor @preconcurrency public required init(rootView: Content) { super.init(frame: .zero) }
    public required init?(coder: NSCoder) { super.init(frame: .zero) }
}
