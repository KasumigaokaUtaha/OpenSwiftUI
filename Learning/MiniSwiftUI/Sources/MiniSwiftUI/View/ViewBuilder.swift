// ViewBuilder.swift
//
// @ViewBuilder 只是一个 result builder：它把 body 里的多条语句变成「类型里写满了
// 结构」的值。比如
//
//     VStack { Text("a"); if flag { Text("b") } else { Color.red } }
//
// 的 content 类型是 TupleView<Text, _ConditionalContent<Text, Color>>。
// 视图的结构编码在类型里 → _makeView 是静态方法 → 图的「形状」在构建期就确定了，
// 运行期只有值在变。这是 SwiftUI 能做到高效增量更新的根本原因。

@resultBuilder
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }

    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<repeat each Content> {
        TupleView((repeat each content))
    }

    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }

    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> {
        _ConditionalContent(storage: .trueContent(first))
    }

    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> {
        _ConditionalContent(storage: .falseContent(second))
    }
}

// MARK: - EmptyView

public struct EmptyView: View, _PrimitiveView {
    public init() {}

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        var outputs = _ViewOutputs()
        outputs.layoutComputer = Attribute(value: .empty)
        return outputs
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs {
        .empty
    }
}

// MARK: - TupleView

/// 多个子视图的静态组合。它是「多元」视图：在列表中展开成多个位置。
public struct TupleView<each Content: View>: View, _PrimitiveView {
    public var value: (repeat each Content)

    public init(_ value: (repeat each Content)) { self.value = value }

    static var count: Int {
        var n = 0
        func add<T>(_: T.Type) { n += 1 }
        _ = (repeat add((each Content).self))
        return n
    }

    static func element<E>(_ tuple: Any, at index: Int, count: Int) -> E {
        // 真实 SwiftUI 用 TupleTypeDescription 从类型元数据中读出每个元素的偏移，
        // 这里用 Mirror 取元组的第 index 个元素。只有一个元素时元组退化为元素本身。
        if count == 1 { return tuple as! E }
        let children = Mirror(reflecting: tuple).children
        return children[children.index(children.startIndex, offsetBy: index)].value as! E
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs {
        let count = Self.count
        var lists: [_ViewListOutputs] = []
        var index = 0
        func add<E: View>(_: E.Type) {
            let i = index
            index += 1
            let child = view.value.map("TupleView[\(i)]") { tuple -> E in
                Self.element(tuple.value, at: i, count: count)
            }
            lists.append(E._makeViewList(view: _GraphValue(child), inputs: inputs))
        }
        _ = (repeat add((each Content).self))
        return .concat(lists)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        // 多元视图被当成单个视图使用时（例如作为 body 的根），隐式包一层 VStack。
        // 真实 SwiftUI：MultiView.makeImplicitRoot。
        makeImplicitRoot(list: _makeViewList(view: view, inputs: inputs), inputs: inputs)
    }
}

// MARK: - 动态视图：if/else、Optional、AnyView

/// `if/else` 生成的视图。分支切换时，旧分支的整个 Subgraph 被销毁（其中的 @State 随之消失），
/// 新分支在一个新的 Subgraph 中重新安装 —— 这就是「结构化身份（structural identity）」。
public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View, _PrimitiveView {
    public enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }
    public let storage: Storage

    public init(storage: Storage) { self.storage = storage }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        makeDynamicView(
            view: view, inputs: inputs,
            childID: { content -> AnyHashable in
                if case .trueContent = content.storage { return "true" } else { return "false" }
            },
            makeChild: { id, view, inputs in
                if id == AnyHashable("true") {
                    let child = Attribute(ConditionalChild<Self, TrueContent>(view: view) {
                        if case let .trueContent(c) = $0.storage { return c } else { return nil }
                    })
                    return TrueContent._makeView(view: _GraphValue(child), inputs: inputs)
                } else {
                    let child = Attribute(ConditionalChild<Self, FalseContent>(view: view) {
                        if case let .falseContent(c) = $0.storage { return c } else { return nil }
                    })
                    return FalseContent._makeView(view: _GraphValue(child), inputs: inputs)
                }
            }
        )
    }
}

/// 从父视图中取出当前分支的子视图值；分支不匹配时（即将被销毁）保持旧值。
struct ConditionalChild<Parent, Child>: StatefulRule, CustomStringConvertible {
    typealias Value = Child
    @Attribute var view: Parent
    let extract: (Parent) -> Child?

    init(view: Attribute<Parent>, extract: @escaping (Parent) -> Child?) {
        _view = view
        self.extract = extract
    }

    mutating func updateValue() {
        if let child = extract(view) { value = child }
    }

    var description: String { "Branch<\(Child.self)>" }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { preconditionFailure() }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        makeDynamicView(
            view: view, inputs: inputs,
            childID: { $0 == nil ? "none" : "some" },
            makeChild: { id, view, inputs in
                if id == AnyHashable("some") {
                    let child = Attribute(ConditionalChild<Self, Wrapped>(view: view) { $0 })
                    return Wrapped._makeView(view: _GraphValue(child), inputs: inputs)
                }
                return EmptyView._makeView(view: _GraphValue(Attribute(value: EmptyView())), inputs: inputs)
            }
        )
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs {
        .unary { inputs in Self._makeView(view: view, inputs: inputs) }
    }
}

/// 类型擦除视图。底层类型一变，就当作一个全新的视图重新安装。
public struct AnyView: View, _PrimitiveView {
    let storage: any View

    public init<V: View>(_ view: V) { storage = view }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        makeDynamicView(
            view: view, inputs: inputs,
            childID: { AnyHashable(ObjectIdentifier(type(of: $0.storage))) },
            makeChild: { _, view, inputs in
                // 打开存在类型，拿到具体的 V。
                func make<V: View>(_: V) -> _ViewOutputs {
                    let child = Attribute(ConditionalChild<AnyView, V>(view: view) { $0.storage as? V })
                    return V._makeView(view: _GraphValue(child), inputs: inputs)
                }
                let storage: any View = Graph.shared.withoutUpdate { view.value.storage }
                return _openExistential(storage, do: make)
            }
        )
    }
}

extension View {
    public func eraseToAnyView() -> AnyView { AnyView(self) }
}
