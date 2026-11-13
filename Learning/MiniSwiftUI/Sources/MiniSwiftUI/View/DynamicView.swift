// DynamicView.swift
//
// 大多数视图在构建期就确定了图的形状。但 if/else、Optional、AnyView 的子视图「类型/分支」
// 要到运行期才知道。真实 SwiftUI 的做法（DynamicView 协议 + DynamicViewContainer，
// 以及 _ConditionalContent.Container）：
//
//   1. 建一个容器规则节点，读取视图值，算出「子视图身份」（分支、类型……）。
//   2. 身份变化时：销毁旧的子 Subgraph，新建一个子 Subgraph，在里面调用子视图的 _makeView。
//   3. 容器的输出用「间接节点」（IndirectAttribute）转发给父视图：父视图拿到的节点 ID
//      永远不变，只是它的数据源被重定向到新子图的输出上。
//
// MiniSwiftUI 用「读取容器值再读取子输出」的映射节点来模拟间接节点。

struct DynamicViewInfo {
    var id: AnyHashable
    var outputs: _ViewOutputs
    var subgraph: Subgraph
}

struct DynamicViewContainer<V>: StatefulRule, CustomStringConvertible {
    typealias Value = DynamicViewInfo
    @Attribute var view: V
    let inputs: _ViewInputs
    let parentSubgraph: Subgraph?
    let childID: (V) -> AnyHashable
    let makeChild: (AnyHashable, Attribute<V>, _ViewInputs) -> _ViewOutputs

    mutating func updateValue() {
        let id = childID(view)
        if hasValue, value.id == id { return }
        if hasValue {
            value.subgraph.invalidate() // 旧分支 —— 连同它的 @State —— 一起消失
        }
        let subgraph = Subgraph(name: "\(V.self):\(id)")
        parentSubgraph?.addChild(subgraph)
        let (makeChild, view, inputs) = (self.makeChild, $view, self.inputs)
        let outputs = subgraph.apply { makeChild(id, view, inputs) }
        value = DynamicViewInfo(id: id, outputs: outputs, subgraph: subgraph)
    }

    var description: String { "DynamicViewContainer<\(V.self)>" }
}

func makeDynamicView<V>(
    view: _GraphValue<V>,
    inputs: _ViewInputs,
    childID: @escaping (V) -> AnyHashable,
    makeChild: @escaping (AnyHashable, Attribute<V>, _ViewInputs) -> _ViewOutputs
) -> _ViewOutputs {
    let container = Attribute(DynamicViewContainer(
        view: view.value, inputs: inputs, parentSubgraph: Subgraph.current,
        childID: childID, makeChild: makeChild
    ))
    var outputs = _ViewOutputs()
    outputs.layoutComputer = container.map("IndirectLayoutComputer") { info in
        info.outputs.layoutComputer?.value ?? .default
    }
    for key in inputs.preferenceKeys.types {
        func forward<K: PreferenceKey>(_: K.Type) {
            outputs[K.self] = container.map("IndirectPreference<\(K.self)>") { info in
                info.outputs[K.self]?.value ?? K.defaultValue
            }
        }
        forward(key)
    }
    return outputs
}
