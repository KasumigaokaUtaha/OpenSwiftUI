// LayoutComputer.swift
//
// SwiftUI 的布局是一场「协商」：
//   1. 父视图向子视图提议一个尺寸（ProposedSize）；
//   2. 子视图回答自己想要的尺寸（sizeThatFits）；
//   3. 父视图决定每个孩子的最终位置和尺寸（childGeometries / placement）。
//
// 在图中，每个视图的 outputs 里有一个 `layoutComputer` 节点，值是 LayoutComputer：
// 一个可以被父视图反复询问 sizeThatFits 的对象。父容器的 LayoutComputer 节点依赖所有
// 孩子的 LayoutComputer 节点；父容器再产生一个「孩子几何」节点，每个孩子的
// position / size 输入都是从这个节点投影出来的。于是：
//
//     孩子内容变化 → 孩子的 LayoutComputer 变化 → 父 LayoutComputer 变化
//       → 父的孩子几何变化 → 各孩子的 position/size 变化 → 显示列表变化
//
// 而如果某个孩子变化后尺寸其实没变，传播就会在比较值时被截断。

public protocol LayoutEngine {
    func sizeThatFits(_ proposal: ProposedSize) -> Size
    /// 给定自身最终的尺寸和位置，算出每个孩子的几何（多孩子容器需要）。
    func childGeometries(at size: Size, origin: Point) -> [ViewGeometry]
    /// EmptyView 之类的「空」布局，栈会跳过它（不为它留间距）。
    var isEmptyLayout: Bool { get }
}

extension LayoutEngine {
    public func childGeometries(at size: Size, origin: Point) -> [ViewGeometry] { [] }
    public var isEmptyLayout: Bool { false }
}

/// 图中流动的布局值。按 seed 比较：引擎没变就复用旧 seed，下游就会认为「没变」。
/// 真实 SwiftUI：LayoutComputer（内部是 AnyLayoutEngineBox + seed，还带尺寸缓存）。
public struct LayoutComputer: Equatable {
    public let engine: any LayoutEngine
    let seed: Int

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.seed == rhs.seed }

    public func sizeThatFits(_ proposal: ProposedSize) -> Size { engine.sizeThatFits(proposal) }

    public func childGeometries(at size: Size, origin: Point) -> [ViewGeometry] {
        engine.childGeometries(at: size, origin: origin)
    }

    static var nextSeed = 2
    public static let `default` = LayoutComputer(engine: DefaultLayoutEngine(), seed: 0)
    public static let empty = LayoutComputer(engine: EmptyLayoutEngine(), seed: 1)
}

/// 没有提供布局的视图：接受提议尺寸。
struct DefaultLayoutEngine: LayoutEngine {
    func sizeThatFits(_ p: ProposedSize) -> Size { Size(width: p.width ?? 0, height: p.height ?? 0) }
}

struct EmptyLayoutEngine: LayoutEngine {
    func sizeThatFits(_ p: ProposedSize) -> Size { .zero }
    var isEmptyLayout: Bool { true }
}

extension StatefulRule where Value == LayoutComputer {
    /// 只有引擎（及其参数）确实变化时才产生新的 LayoutComputer。
    /// 真实 SwiftUI：StatefulRule.updateLayoutComputer。
    mutating func updateLayoutComputer(_ engine: any LayoutEngine) {
        if hasValue, _compareAny(value.engine, engine) { return }
        LayoutComputer.nextSeed += 1
        value = LayoutComputer(engine: engine, seed: LayoutComputer.nextSeed)
    }
}

// MARK: - 叶子视图

struct LeafLayoutComputer<V>: StatefulRule, CustomStringConvertible {
    typealias Value = LayoutComputer
    @Attribute var view: V
    @Attribute var environment: EnvironmentValues
    let makeEngine: (V, EnvironmentValues) -> any LayoutEngine

    mutating func updateValue() {
        updateLayoutComputer(makeEngine(view, environment))
    }

    var description: String { "LayoutComputer(\(V.self))" }
}

struct LeafDisplayList<V>: Rule, CustomStringConvertible {
    @Attribute var view: V
    @Attribute var position: Point
    @Attribute var size: Size
    @Attribute var environment: EnvironmentValues
    let content: (V, Size, EnvironmentValues) -> DisplayList.Content?

    var value: DisplayList {
        guard let content = content(view, size, environment) else { return DisplayList() }
        let identity = Graph.shared.currentAttribute?.rawValue ?? 0
        return DisplayList(DisplayList.Item(
            frame: Rect(origin: position, size: size),
            value: .content(content),
            identity: identity
        ))
    }

    var description: String { "DisplayList(\(V.self))" }
}

extension _ViewInputs {
    /// 叶子视图的通用安装流程：一个布局节点 + （若有人要）一个显示列表节点。
    func makeLeafView<V>(
        view: _GraphValue<V>,
        layout: @escaping (V, EnvironmentValues) -> any LayoutEngine,
        content: @escaping (V, Size, EnvironmentValues) -> DisplayList.Content?
    ) -> _ViewOutputs {
        var outputs = _ViewOutputs()
        outputs.layoutComputer = Attribute(LeafLayoutComputer(
            view: view.value, environment: base.environment, makeEngine: layout
        ))
        if preferenceKeys.contains(DisplayList.Key.self) {
            outputs[DisplayList.Key.self] = Attribute(LeafDisplayList(
                view: view.value, position: position, size: size,
                environment: base.environment, content: content
            ))
        }
        return outputs
    }
}

// MARK: - 一元布局（padding、frame……）

/// 只有一个孩子的布局（真实：UnaryLayout）。
public protocol UnaryLayout {
    func sizeThatFits(in proposal: ProposedSize, child: LayoutComputer) -> Size
    /// 孩子在自身坐标系中的位置与尺寸。
    func placement(of child: LayoutComputer, in size: Size) -> Rect
}

struct UnaryLayoutEngine<L: UnaryLayout>: LayoutEngine {
    let layout: L
    let child: LayoutComputer
    func sizeThatFits(_ p: ProposedSize) -> Size { layout.sizeThatFits(in: p, child: child) }
}

struct UnaryLayoutComputer<L: UnaryLayout>: StatefulRule, CustomStringConvertible {
    typealias Value = LayoutComputer
    @Attribute var layout: L
    @Attribute var child: LayoutComputer
    mutating func updateValue() { updateLayoutComputer(UnaryLayoutEngine(layout: layout, child: child)) }
    var description: String { "LayoutComputer(\(L.self))" }
}

struct UnaryChildGeometry<L: UnaryLayout>: Rule, CustomStringConvertible {
    @Attribute var layout: L
    @Attribute var parentSize: Size
    @Attribute var parentPosition: Point
    var child: Attribute<LayoutComputer>?

    var value: ViewGeometry {
        let rect = layout.placement(of: child?.value ?? .default, in: parentSize)
        return ViewGeometry(origin: parentPosition + rect.origin, size: rect.size)
    }
    var description: String { "ChildGeometry(\(L.self))" }
}

func makeUnaryLayout<L: UnaryLayout>(
    layout: _GraphValue<L>,
    inputs: _ViewInputs,
    body: (_ViewInputs) -> _ViewOutputs
) -> _ViewOutputs {
    // 先建「孩子几何」节点（此时还不知道孩子的 LayoutComputer），
    // 安装孩子之后再用 mutateBody 把孩子的 LayoutComputer 塞回去。
    let geometry = Attribute(UnaryChildGeometry(
        layout: layout.value, parentSize: inputs.size, parentPosition: inputs.position, child: nil
    ))
    var childInputs = inputs
    childInputs.position = geometry.origin
    childInputs.size = geometry.size
    childInputs.stackAxis = nil
    var outputs = body(childInputs)
    let childLayout = outputs.layoutComputer ?? Attribute(value: .default)
    geometry.mutateBody(as: UnaryChildGeometry<L>.self, invalidating: true) { $0.child = childLayout }
    outputs.layoutComputer = Attribute(UnaryLayoutComputer(layout: layout.value, child: childLayout))
    return outputs
}

// MARK: - padding

public struct _PaddingLayout: UnaryLayout, _PrimitiveViewModifier {
    public var insets: EdgeInsets

    public func sizeThatFits(in proposal: ProposedSize, child: LayoutComputer) -> Size {
        let s = child.sizeThatFits(proposal.inset(by: insets))
        return Size(width: s.width + insets.leading + insets.trailing, height: s.height + insets.top + insets.bottom)
    }

    public func placement(of child: LayoutComputer, in size: Size) -> Rect {
        let inner = Size(
            width: max(0, size.width - insets.leading - insets.trailing),
            height: max(0, size.height - insets.top - insets.bottom)
        )
        let s = child.sizeThatFits(ProposedSize(inner))
        return Rect(origin: Point(x: insets.leading, y: insets.top), size: s)
    }

    public static func _makeView(
        modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        makeUnaryLayout(layout: modifier, inputs: inputs, body: body)
    }
}

// MARK: - frame

public struct _FrameLayout: UnaryLayout, _PrimitiveViewModifier {
    public var width: Double?
    public var height: Double?

    public func sizeThatFits(in p: ProposedSize, child: LayoutComputer) -> Size {
        if let width, let height { return Size(width: width, height: height) }
        let s = child.sizeThatFits(ProposedSize(width: width ?? p.width, height: height ?? p.height))
        return Size(width: width ?? s.width, height: height ?? s.height)
    }

    public func placement(of child: LayoutComputer, in size: Size) -> Rect {
        let s = child.sizeThatFits(ProposedSize(size))
        // 居中对齐
        let origin = Point(x: ((size.width - s.width) / 2).rounded(.down), y: ((size.height - s.height) / 2).rounded(.down))
        return Rect(origin: origin, size: s)
    }

    public static func _makeView(
        modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        makeUnaryLayout(layout: modifier, inputs: inputs, body: body)
    }
}

extension View {
    public func padding(_ length: Double = 1) -> some View {
        modifier(_PaddingLayout(insets: EdgeInsets(length)))
    }

    public func padding(_ insets: EdgeInsets) -> some View {
        modifier(_PaddingLayout(insets: insets))
    }

    public func frame(width: Double? = nil, height: Double? = nil) -> some View {
        modifier(_FrameLayout(width: width, height: height))
    }
}
