// Stack.swift
//
// 多孩子布局容器（VStack / HStack / ZStack）。
//
// 安装流程分两条路径，与真实 SwiftUI 的 Layout.makeStaticView / makeDynamicView 对应：
//
//   静态路径（孩子数量在构建期就确定）：
//     StaticLayoutComputer ──► LayoutChildGeometries ──► ChildGeometry[i] ──► 孩子 i 的 position/size
//            ▲                                                                       │
//            └────────────────────── 孩子 i 的 layoutComputer ◄───────────────────────┘
//
//   动态路径（含 ForEach）：
//     DynamicContainer 节点读取「元素 ID 列表」，按 ID 增删子 Subgraph（真实：DynamicContainer
//     + DynamicLayoutMap）。布局与偏好节点再从容器的当前值中读取各孩子的输出。

public enum StackAlignment: Equatable { case start, center, end }

/// 一个多孩子布局：给定孩子们的 LayoutComputer，产生自己的布局引擎。
public protocol _MultiLayout {
    static var axis: Axis? { get }
    func makeEngine(children: [LayoutComputer]) -> any LayoutEngine
}

// MARK: - 栈布局算法

struct StackLayoutEngine: LayoutEngine {
    let axis: Axis
    let spacing: Double
    let alignment: StackAlignment
    let children: [LayoutComputer]

    private var active: [Int] { children.indices.filter { !children[$0].engine.isEmptyLayout } }

    /// SwiftUI 栈的经典分配算法（简化版）：
    ///   1. 先用 0 和 ∞ 两个提议测出每个孩子沿主轴的最小/最大尺寸，差值即「弹性」；
    ///   2. 从最不灵活的孩子开始，每次把「剩余空间 / 剩余孩子数」提议给它；
    ///   3. 它实际拿走多少，就从剩余空间中扣掉多少。
    /// 所以 Text 拿到正好够用的宽度，Spacer/Color 这类灵活的孩子瓜分剩下的空间。
    func childSizes(for proposal: ProposedSize) -> [Size] {
        let indices = active
        guard !indices.isEmpty else { return [] }
        let minor = proposal[axis.other]
        guard let major = proposal[axis] else {
            return indices.map { children[$0].sizeThatFits(ProposedSize(axis: axis, major: nil, minor: minor)) }
        }
        var remaining = max(0, major - spacing * Double(indices.count - 1))
        let flexibility = indices.map { i -> Double in
            let lo = children[i].sizeThatFits(ProposedSize(axis: axis, major: 0, minor: minor))[axis]
            let hi = children[i].sizeThatFits(ProposedSize(axis: axis, major: .infinity, minor: minor))[axis]
            return hi - lo
        }
        let order = indices.indices.sorted { a, b in
            flexibility[a] != flexibility[b] ? flexibility[a] < flexibility[b] : a < b
        }
        var sizes = Array(repeating: Size.zero, count: indices.count)
        var left = indices.count
        for k in order {
            let share = (remaining / Double(left)).rounded(.down)
            let size = children[indices[k]].sizeThatFits(ProposedSize(axis: axis, major: share, minor: minor))
            sizes[k] = size
            remaining = max(0, remaining - size[axis])
            left -= 1
        }
        return sizes
    }

    func sizeThatFits(_ proposal: ProposedSize) -> Size {
        let sizes = childSizes(for: proposal)
        guard !sizes.isEmpty else { return .zero }
        var result = Size.zero
        result[axis] = sizes.reduce(0) { $0 + $1[axis] } + spacing * Double(sizes.count - 1)
        result[axis.other] = sizes.map { $0[axis.other] }.max() ?? 0
        return result
    }

    func childGeometries(at size: Size, origin: Point) -> [ViewGeometry] {
        let sizes = childSizes(for: ProposedSize(size))
        var result = Array(repeating: ViewGeometry(origin: origin, size: .zero), count: children.count)
        var cursor = 0.0
        for (k, i) in active.enumerated() {
            let s = sizes[k]
            let free = size[axis.other] - s[axis.other]
            let offset: Double = switch alignment {
            case .start: 0
            case .center: (free / 2).rounded(.down)
            case .end: free
            }
            var p = Point.zero
            if axis == .horizontal { p = Point(x: cursor, y: offset) } else { p = Point(x: offset, y: cursor) }
            result[i] = ViewGeometry(origin: origin + p, size: s)
            cursor += s[axis] + spacing
        }
        return result
    }
}

struct ZStackLayoutEngine: LayoutEngine {
    let children: [LayoutComputer]

    func sizeThatFits(_ p: ProposedSize) -> Size {
        let sizes = children.map { $0.sizeThatFits(p) }
        return Size(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }

    func childGeometries(at size: Size, origin: Point) -> [ViewGeometry] {
        children.map { child in
            let s = child.sizeThatFits(ProposedSize(size))
            let p = Point(x: ((size.width - s.width) / 2).rounded(.down), y: ((size.height - s.height) / 2).rounded(.down))
            return ViewGeometry(origin: origin + p, size: s)
        }
    }
}

// MARK: - 布局值

public struct _VStackLayout: _MultiLayout {
    public var spacing: Double
    public var alignment: StackAlignment
    public static var axis: Axis? { .vertical }
    public func makeEngine(children: [LayoutComputer]) -> any LayoutEngine {
        StackLayoutEngine(axis: .vertical, spacing: spacing, alignment: alignment, children: children)
    }
}

public struct _HStackLayout: _MultiLayout {
    public var spacing: Double
    public var alignment: StackAlignment
    public static var axis: Axis? { .horizontal }
    public func makeEngine(children: [LayoutComputer]) -> any LayoutEngine {
        StackLayoutEngine(axis: .horizontal, spacing: spacing, alignment: alignment, children: children)
    }
}

public struct _ZStackLayout: _MultiLayout {
    public static var axis: Axis? { nil }
    public func makeEngine(children: [LayoutComputer]) -> any LayoutEngine {
        ZStackLayoutEngine(children: children)
    }
}

// MARK: - 视图

public struct VStack<Content: View>: View, _PrimitiveView {
    public var layout: _VStackLayout
    public var content: Content

    public init(alignment: StackAlignment = .center, spacing: Double = 0, @ViewBuilder content: () -> Content) {
        layout = _VStackLayout(spacing: spacing, alignment: alignment)
        self.content = content()
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        makeLayoutView(layout: view[\.layout], list: Content._makeViewList(view: view[\.content], inputs: inputs), inputs: inputs)
    }
}

public struct HStack<Content: View>: View, _PrimitiveView {
    public var layout: _HStackLayout
    public var content: Content

    public init(alignment: StackAlignment = .center, spacing: Double = 1, @ViewBuilder content: () -> Content) {
        layout = _HStackLayout(spacing: spacing, alignment: alignment)
        self.content = content()
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        makeLayoutView(layout: view[\.layout], list: Content._makeViewList(view: view[\.content], inputs: inputs), inputs: inputs)
    }
}

public struct ZStack<Content: View>: View, _PrimitiveView {
    public var layout = _ZStackLayout()
    public var content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        makeLayoutView(layout: view[\.layout], list: Content._makeViewList(view: view[\.content], inputs: inputs), inputs: inputs)
    }
}

/// 多元视图作为根时的隐式容器。
func makeImplicitRoot(list: _ViewListOutputs, inputs: _ViewInputs) -> _ViewOutputs {
    makeLayoutView(layout: _GraphValue(Attribute(value: _VStackLayout(spacing: 0, alignment: .center))), list: list, inputs: inputs)
}

// MARK: - 安装

func makeLayoutView<L: _MultiLayout>(layout: _GraphValue<L>, list: _ViewListOutputs, inputs: _ViewInputs) -> _ViewOutputs {
    switch list {
    case let .staticList(elements):
        return makeStaticLayoutView(layout: layout.value, elements: elements, inputs: inputs)
    case let .dynamicList(items):
        return makeDynamicLayoutView(layout: layout.value, items: items, inputs: inputs)
    }
}

struct StaticLayoutComputer<L: _MultiLayout>: StatefulRule, CustomStringConvertible {
    typealias Value = LayoutComputer
    @Attribute var layout: L
    var children: [Attribute<LayoutComputer>]
    mutating func updateValue() {
        updateLayoutComputer(layout.makeEngine(children: children.map(\.value)))
    }
    var description: String { "LayoutComputer(\(L.self))" }
}

struct LayoutChildGeometries: Rule, CustomStringConvertible {
    @Attribute var parentSize: Size
    @Attribute var parentPosition: Point
    @Attribute var layoutComputer: LayoutComputer
    var value: [ViewGeometry] { layoutComputer.childGeometries(at: parentSize, origin: parentPosition) }
    var description: String { "LayoutChildGeometries" }
}

func makeStaticLayoutView<L: _MultiLayout>(layout: Attribute<L>, elements: [_ViewListElement], inputs: _ViewInputs) -> _ViewOutputs {
    let layoutComputer = Attribute(StaticLayoutComputer(layout: layout, children: []))
    let geometries = Attribute(LayoutChildGeometries(
        parentSize: inputs.size, parentPosition: inputs.position, layoutComputer: layoutComputer
    ))
    let axis = L.axis
    var children: [_ViewOutputs] = []
    for (index, element) in elements.enumerated() {
        let geometry = geometries.map("ChildGeometry[\(index)]") { $0[index] }
        var childInputs = inputs
        childInputs.position = geometry.origin
        childInputs.size = geometry.size
        childInputs.stackAxis = axis
        children.append(element.make(childInputs))
    }
    let childLayouts = children.map { $0.layoutComputer ?? Attribute(value: .default) }
    layoutComputer.mutateBody(as: StaticLayoutComputer<L>.self, invalidating: true) { $0.children = childLayouts }

    var outputs = combinePreferences(children, keys: inputs.preferenceKeys)
    outputs.layoutComputer = layoutComputer
    return outputs
}

// MARK: - 动态容器（ForEach）

struct DynamicContainerInfo {
    var ids: [AnyHashable]
    var outputs: [_ViewOutputs]
}

struct DynamicContainer: StatefulRule, CustomStringConvertible {
    typealias Value = DynamicContainerInfo
    @Attribute var items: [_DynamicListItem]
    let inputs: _ViewInputs
    let parentSubgraph: Subgraph?
    let axis: Axis?
    var geometries: Attribute<[AnyHashable: ViewGeometry]>?
    var live: [AnyHashable: (subgraph: Subgraph, outputs: _ViewOutputs)] = [:]

    mutating func updateValue() {
        let items = items
        let newIDs = Set(items.map(\.id))
        // 1. 销毁不再存在的元素 —— 它的整个子图（含 @State）被丢弃。
        for (id, entry) in live where !newIDs.contains(id) {
            entry.subgraph.invalidate()
            live[id] = nil
        }
        // 2. 为新出现的元素建子图并安装视图。
        for item in items where live[item.id] == nil {
            let subgraph = Subgraph(name: "item:\(item.id)")
            parentSubgraph?.addChild(subgraph)
            let (geometries, inputs, axis, id) = (self.geometries!, self.inputs, self.axis, item.id)
            let outputs = subgraph.apply { () -> _ViewOutputs in
                let geometry = geometries.map("ItemGeometry(\(id))") { $0[id] ?? .zero }
                var childInputs = inputs
                childInputs.position = geometry.origin
                childInputs.size = geometry.size
                childInputs.stackAxis = axis
                return item.make(childInputs)
            }
            live[item.id] = (subgraph, outputs)
        }
        // 3. 输出按当前顺序排列的孩子。已有元素的子图原封不动地复用。
        value = DynamicContainerInfo(ids: items.map(\.id), outputs: items.map { live[$0.id]!.outputs })
    }

    var description: String { "DynamicContainer" }
}

struct DynamicLayoutComputer<L: _MultiLayout>: StatefulRule, CustomStringConvertible {
    typealias Value = LayoutComputer
    @Attribute var layout: L
    @Attribute var container: DynamicContainerInfo
    mutating func updateValue() {
        let children = container.outputs.map { $0.layoutComputer?.value ?? .default }
        updateLayoutComputer(layout.makeEngine(children: children))
    }
    var description: String { "DynamicLayoutComputer(\(L.self))" }
}

struct DynamicChildGeometries: Rule, CustomStringConvertible {
    @Attribute var parentSize: Size
    @Attribute var parentPosition: Point
    @Attribute var layoutComputer: LayoutComputer
    @Attribute var container: DynamicContainerInfo
    var value: [AnyHashable: ViewGeometry] {
        let geometries = layoutComputer.childGeometries(at: parentSize, origin: parentPosition)
        return Dictionary(uniqueKeysWithValues: zip(container.ids, geometries))
    }
    var description: String { "DynamicChildGeometries" }
}

struct DynamicPreferenceCombiner<K: PreferenceKey>: Rule, CustomStringConvertible {
    @Attribute var container: DynamicContainerInfo
    var value: K.Value {
        PreferenceCombiner<K>(children: container.outputs.compactMap { $0[K.self] }).value
    }
    var description: String { "DynamicPreferenceCombiner<\(K.self)>" }
}

func makeDynamicLayoutView<L: _MultiLayout>(layout: Attribute<L>, items: Attribute<[_DynamicListItem]>, inputs: _ViewInputs) -> _ViewOutputs {
    let axis = L.axis
    let container = Attribute(DynamicContainer(
        items: items, inputs: inputs, parentSubgraph: Subgraph.current, axis: axis, geometries: nil
    ))
    let layoutComputer = Attribute(DynamicLayoutComputer(layout: layout, container: container))
    let geometries = Attribute(DynamicChildGeometries(
        parentSize: inputs.size, parentPosition: inputs.position,
        layoutComputer: layoutComputer, container: container
    ))
    container.mutateBody(as: DynamicContainer.self, invalidating: false) { $0.geometries = geometries }

    var outputs = _ViewOutputs()
    outputs.layoutComputer = layoutComputer
    for key in inputs.preferenceKeys.types {
        func combine<K: PreferenceKey>(_: K.Type) {
            outputs[K.self] = Attribute(DynamicPreferenceCombiner<K>(container: container))
        }
        combine(key)
    }
    return outputs
}
