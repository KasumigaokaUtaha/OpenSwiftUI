// View.swift
//
// SwiftUI 最核心的一个事实：View 不是「视图对象」，而是「描述」。
// 一个 View 类型真正重要的不是 body，而是那个带下划线的静态方法：
//
//     static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs
//
// 它在「图构建期」只被调用一次（每个视图位置一次），作用是：
//   拿到一个代表「本视图值」的图节点（view）和父视图传下来的一组输入节点（inputs：
//   环境、位置、尺寸、事务……），往图里添加若干规则节点，然后返回一组输出节点
//   （outputs：布局计算器、显示列表等偏好值）。
//
// 之后状态变化时 SwiftUI 不会再调用 _makeView，只会让图增量地重新计算受影响的节点。
// 「body 被调用」只是图中某个规则节点（DynamicBody/StaticBody）被重新求值而已。

public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }

    /// 把本视图「安装」进图中。
    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs

    /// 以「视图列表」的形式安装本视图（供 VStack/HStack 等容器使用，见 ViewList.swift）。
    static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

/// 没有 body 的「原语视图」：Text、Color、VStack、ModifiedContent……
/// 它们必须自己实现 _makeView（真实 SwiftUI：PrimitiveView）。
public protocol _PrimitiveView: View where Body == Never {}

extension _PrimitiveView {
    public var body: Never { preconditionFailure("body() should not be called on \(Self.self).") }
}

// MARK: - 默认实现：通过 body 递归

extension View {
    /// 自定义视图的默认 _makeView（真实 SwiftUI：View.makeView，见 OpenSwiftUICore/View/CustomView.swift）：
    ///   1. 创建一个 body 规则节点：输入是本视图的值，输出是 `view.body`；
    ///   2. 递归调用 `Body._makeView`，把 body 节点当作子视图安装。
    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        precondition(Body.self != Never.self, "\(Self.self) 是原语视图，必须自己实现 _makeView")
        let body = makeBody(view: view, inputs: inputs)
        return Body._makeView(view: body, inputs: inputs)
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs {
        if Body.self == Never.self {
            // 原语视图默认是「一元」的：在列表中占一个位置。
            return .unary { inputs in Self._makeView(view: view, inputs: inputs) }
        }
        let body = makeBody(view: view, inputs: inputs)
        return Body._makeViewList(view: body, inputs: inputs)
    }

    static func makeBody(view: _GraphValue<Self>, inputs: _ViewInputs) -> _GraphValue<Body> {
        _GraphValue(Attribute(BodyRule<Self, Body>(
            container: view.value,
            inputs: inputs.base,
            subgraph: Subgraph.current,
            makeBody: { $0.body }
        )))
    }
}

/// body 规则节点。真实 SwiftUI 会根据视图有没有 DynamicProperty 在 StaticBody（无状态）
/// 和 DynamicBody（有状态）之间二选一，见 OpenSwiftUICore/Data/DynamicProperty/DynamicProperty.swift。
/// 这里合二为一：第一次运行时扫描 DynamicProperty，没有就相当于 StaticBody。
struct BodyRule<Container, Body>: StatefulRule, CustomStringConvertible {
    typealias Value = Body
    @Attribute var container: Container
    let inputs: _GraphInputs
    let subgraph: Subgraph?
    let makeBody: (Container) -> Body
    var buffer: _DynamicPropertyBuffer?

    init(container: Attribute<Container>, inputs: _GraphInputs, subgraph: Subgraph?, makeBody: @escaping (Container) -> Body) {
        _container = container
        self.inputs = inputs
        self.subgraph = subgraph
        self.makeBody = makeBody
    }

    mutating func updateValue() {
        let (container, containerChanged) = $container.changedValue()
        var changed = containerChanged
        if buffer == nil {
            let inputs = self.inputs
            let make = { _DynamicPropertyBuffer(scanning: container, inputs: inputs) }
            buffer = subgraph.map { $0.apply(make) } ?? Graph.shared.withoutUpdate(make)
        }
        // 把图中的状态注入这一次新鲜的视图值，并检查有没有变化。
        if buffer!.update(container: container) { changed = true }
        // 只有视图本身或它的动态属性变了，才真正调用 body。
        if changed || !hasValue {
            // 记录「真正调用了 body」，与「规则节点被重新运行」区分开。
            Graph.shared.traceLog?.append("body(\(String(describing: Container.self)))")
            value = makeBody(container)
        }
    }

    var description: String { "BodyRule<\(String(describing: Container.self))>" }
}

// MARK: - _GraphValue

/// 「图中某个类型为 Value 的节点」。_makeView 拿到的不是视图值，而是它。
public struct _GraphValue<Value> {
    public let value: Attribute<Value>
    public init(_ value: Attribute<Value>) { self.value = value }

    /// 投影出子字段，例如 `view[\.content]`（真实：`view[offset: { .of(&$0.content) }]`）。
    public subscript<Member>(keyPath: KeyPath<Value, Member>) -> _GraphValue<Member> {
        _GraphValue<Member>(value[keyPath: keyPath])
    }
}

// MARK: - Inputs / Outputs

/// 与具体视图无关的图输入（真实：_GraphInputs）。
public struct _GraphInputs {
    public var environment: Attribute<EnvironmentValues>
    public var transaction: Attribute<Transaction>
    public var time: Attribute<Double>
}

/// 视图的输入（真实：_ViewInputs）。父视图通过修改它来影响子视图：
/// `.environment` 换掉 environment，布局容器换掉 position/size……
public struct _ViewInputs {
    public var base: _GraphInputs
    /// 视图在根坐标系中的位置与尺寸 —— 由父容器的布局计算产生。
    public var position: Attribute<Point>
    public var size: Attribute<Size>
    /// 祖先「想要」哪些偏好值。没人要的偏好值根本不会被创建（按需计算）。
    public var preferenceKeys = PreferenceKeys()
    /// 如果直接父容器是栈，记录其方向（Spacer 需要知道自己沿哪个方向伸展）。
    var stackAxis: Axis?
    /// 自定义 ViewModifier 的 body 中，`content` 占位符对应的构建闭包。
    var modifierBodies: [ObjectIdentifier: (_ViewInputs) -> _ViewOutputs] = [:]
}

/// 视图的输出（真实：_ViewOutputs）。
public struct _ViewOutputs {
    /// 偏好值：key 的类型 → 图节点。显示列表（DisplayList）本身也是一种偏好！
    var preferences: [ObjectIdentifier: AnyAttribute] = [:]
    /// 布局计算器：父容器通过它询问「给你这么大，你要多大」。
    public var layoutComputer: Attribute<LayoutComputer>?

    public init() {}

    public subscript<K: PreferenceKey>(key: K.Type) -> Attribute<K.Value>? {
        get { preferences[ObjectIdentifier(key)].map { Attribute(identifier: $0) } }
        set { preferences[ObjectIdentifier(key)] = newValue?.identifier }
    }
}
