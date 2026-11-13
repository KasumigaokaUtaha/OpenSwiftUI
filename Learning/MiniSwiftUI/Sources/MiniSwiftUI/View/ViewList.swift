// ViewList.swift
//
// VStack { A; B; ForEach(items) { ... } } 里，VStack 需要知道自己有「哪些孩子」。
// 这就是 _makeViewList 的职责：把一个视图展开成「元素列表」。
//
//   * 一元视图（Text、Color、ModifiedContent……）贡献 1 个元素；
//   * TupleView 把各子视图的列表拼接起来；
//   * EmptyView 贡献 0 个元素；
//   * ForEach 贡献一个「动态列表」：元素个数和身份（ID）在运行期才知道，并且会变化。
//
// 真实 SwiftUI 的 ViewList 体系非常庞大（_ViewListOutputs、ViewList 协议、
// ViewList.Elements、_ViewList_ID、DynamicContainer……，见 OpenSwiftUICore/View/Input/ViewList.swift）。
// 这里只保留两种形态：静态列表（构建期就确定）和动态列表（一个值为 [Item] 的图节点）。

/// 静态列表中的一个元素：给定输入，安装这个元素并返回输出。
public struct _ViewListElement {
    let make: (_ViewInputs) -> _ViewOutputs
}

/// 动态列表中的一个元素。只按 ID 比较 —— ID 不变，就认为「还是那个视图」。
public struct _DynamicListItem: Equatable {
    let id: AnyHashable
    let make: (_ViewInputs) -> _ViewOutputs

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

public enum _ViewListOutputs {
    case staticList([_ViewListElement])
    case dynamicList(Attribute<[_DynamicListItem]>)

    static var empty: _ViewListOutputs { .staticList([]) }

    static func unary(_ make: @escaping (_ViewInputs) -> _ViewOutputs) -> _ViewListOutputs {
        .staticList([_ViewListElement(make: make)])
    }

    /// 拼接多个列表。只要有一个是动态的，结果就是动态的。
    static func concat(_ lists: [_ViewListOutputs]) -> _ViewListOutputs {
        var statics: [_ViewListElement] = []
        var allStatic = true
        for list in lists {
            switch list {
            case let .staticList(elements): statics += elements
            case .dynamicList: allStatic = false
            }
        }
        if allStatic { return .staticList(statics) }

        // 把每一段都转成「动态段」，ID 前面加上段号以保证唯一。
        var parts: [Attribute<[_DynamicListItem]>] = []
        for (partIndex, list) in lists.enumerated() {
            switch list {
            case let .staticList(elements):
                let items = elements.enumerated().map { i, e in
                    _DynamicListItem(id: AnyHashable([AnyHashable(partIndex), AnyHashable(i)]), make: e.make)
                }
                parts.append(Attribute(value: items))
            case let .dynamicList(attribute):
                parts.append(attribute.map("PrefixIDs") { items in
                    items.map { _DynamicListItem(id: AnyHashable([AnyHashable(partIndex), $0.id]), make: $0.make) }
                })
            }
        }
        return .dynamicList(Attribute(ConcatItems(parts: parts)))
    }
}

struct ConcatItems: Rule {
    let parts: [Attribute<[_DynamicListItem]>]
    var value: [_DynamicListItem] { parts.flatMap(\.value) }
}

// MARK: - ForEach

/// 根据数据集合动态生成视图。每个元素的「显式身份」就是它的 ID。
///
/// 当集合变化时：
///   * 新 ID → 为它新建一个 Subgraph 并安装 content 视图；
///   * 消失的 ID → 销毁对应 Subgraph（其中的 @State 一并丢弃）；
///   * 仍在的 ID → 保留 Subgraph，只是元素数据变化时让该行重新计算。
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View, _PrimitiveView {
    public let data: Data
    let id: KeyPath<Data.Element, ID>
    let content: (Data.Element) -> Content

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.content = content
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs {
        let forEachAttribute = view.value
        let items = forEachAttribute.map("ForEach.IDs") { forEach in
            forEach.data.map { element -> _DynamicListItem in
                let id = element[keyPath: forEach.id]
                return _DynamicListItem(id: AnyHashable(id)) { inputs in
                    let row = Attribute(ForEachChild(forEach: forEachAttribute, id: id))
                    return Content._makeView(view: _GraphValue(row), inputs: inputs)
                }
            }
        }
        return .dynamicList(items)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        makeImplicitRoot(list: _makeViewList(view: view, inputs: inputs), inputs: inputs)
    }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: \.id, content: content)
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.init(data, id: \.self, content: content)
    }
}

/// 某一行的视图值：从 ForEach 当前的数据里找到自己的 ID，调用 content 闭包。
struct ForEachChild<Data: RandomAccessCollection, ID: Hashable, Content: View>: StatefulRule, CustomStringConvertible {
    typealias Value = Content
    @Attribute var forEach: ForEach<Data, ID, Content>
    let id: ID

    mutating func updateValue() {
        let forEach = forEach
        if let element = forEach.data.first(where: { $0[keyPath: forEach.id] == id }) {
            value = forEach.content(element)
        }
    }

    var description: String { "ForEachRow(\(id))" }
}
