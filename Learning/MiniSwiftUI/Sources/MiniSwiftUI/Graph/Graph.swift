// Graph.swift
//
// MiniSwiftUI 的「AttributeGraph」。
//
// 真实 SwiftUI 的一切都建立在私有框架 AttributeGraph（AG）之上。AG 是一个
// 增量计算引擎：图中每个节点（attribute）要么是外部写入的值（input），要么
// 是由一条规则（rule）根据其他节点计算出来的值。它的核心算法可以概括为：
//
//   1. 推（push）脏标记：某个 input 被写入新值时，沿着「输出边」把所有下游节点
//      标记为 dirty（真实实现：Graph::propagate_dirty，见 Compute/OpenAttributeGraph）。
//   2. 拉（pull）求值：只有当有人读取一个 dirty 节点时，才去检查它的输入；
//      如果某个输入的值「真的变了」，才重新运行它的规则（Graph::update_attribute
//      + UpdateStack::update）。
//   3. 值比较截断：规则重新计算出的值如果与旧值相等（compareValues），节点的版本号
//      不增加，下游会发现「输入没变」，从而跳过重新计算。
//
// 依赖边是在规则运行时「读到谁就连谁」动态记录的（真实实现：input_value_ref 会
// 在第一次读取时调用 add_input）。
//
// 这里的实现刻意追求可读性而非性能：节点存在数组里、从不回收内存，也没有线程
// 安全。但算法骨架与真实 AG 一致。

/// 一个节点的标识符。真实 AG 中是一个 32 位整数（编码了页指针和偏移）。
public struct AnyAttribute: Hashable, CustomStringConvertible {
    public let rawValue: Int
    public static let `nil` = AnyAttribute(rawValue: -1)
    public var description: String { "#\(rawValue)" }
}

/// 规则体的类型擦除接口。真实 AG 用一张 C 语言 vtable（AGAttributeType）描述它。
protocol _AnyRuleBody {
    mutating func _update()
    mutating func _mutate<T>(_ body: (inout T) -> Void) -> Bool
    var _description: String { get }
}

final class _BodyBox {
    var body: any _AnyRuleBody
    init(_ body: any _AnyRuleBody) { self.body = body }
}

/// 图中的一个节点。
final class Node {
    let id: Int
    let valueType: Any.Type
    /// nil 表示这是一个外部输入节点（由宿主或 State 直接写值）。
    var body: _BodyBox?
    var value: Any?
    /// 值真正发生变化的次数。下游通过比较版本号判断「输入是否变了」。
    var version: UInt64 = 0
    var isDirty = true
    /// 被 mutateBody / invalidateValue 强制要求重新运行。
    var forceRun = false
    var isValid = true
    /// 输入边：依赖了哪个节点，以及「上次运行时看到的版本号」。
    var inputs: [(node: Int, seen: UInt64)] = []
    var inputSet: Set<Int> = []
    /// 输出边：哪些节点依赖了我。
    var outputs: Set<Int> = []
    weak var subgraph: Subgraph?

    init(id: Int, valueType: Any.Type) {
        self.id = id
        self.valueType = valueType
    }

    var description: String {
        body?.body._description ?? "Input<\(valueType)>"
    }
}

public final class Graph {
    /// 与真实 SwiftUI 一样，所有宿主共享一张图（GraphHost.sharedGraph）。
    public static let shared = Graph()

    var nodes: [Node] = []

    /// 正在运行的规则栈（真实 AG：UpdateStack）。
    /// 元素为 nil 表示「不记录依赖」的帧（Graph.withoutUpdate）。
    var updateStack: [Int?] = []

    /// 统计：规则一共运行了多少次。
    public private(set) var ruleEvaluationCount = 0
    var traceLog: [String]?

    /// 当前是否处于图的更新过程中（真实 SwiftUI：GraphHost.isUpdating）。
    public var isUpdating: Bool { updateStack.contains { $0 != nil } }

    // MARK: 创建节点

    func makeNode(valueType: Any.Type, body: (any _AnyRuleBody)?, value: Any?) -> AnyAttribute {
        let node = Node(id: nodes.count, valueType: valueType)
        if let body {
            node.body = _BodyBox(body)
        } else {
            node.value = value
            node.isDirty = false
        }
        nodes.append(node)
        Subgraph.current?.add(node)
        return AnyAttribute(rawValue: node.id)
    }

    func node(_ attribute: AnyAttribute) -> Node {
        precondition(attribute != .nil, "读取了 nil attribute")
        return nodes[attribute.rawValue]
    }

    // MARK: 读取（拉）

    /// 读取一个节点的值。如果当前处在某条规则的求值过程中，会自动记录依赖边。
    func value(of attribute: AnyAttribute) -> Any {
        let n = node(attribute)
        precondition(n.isValid, "读取了已失效的 attribute \(attribute)（它所在的 Subgraph 已被销毁）")
        recordDependency(on: n)
        updateIfNeeded(n)
        guard let value = n.value else {
            preconditionFailure("attribute \(attribute) (\(n.description)) 没有值")
        }
        return value
    }

    /// 读取值，并告诉调用者「自当前规则上次运行以来，这个输入是否变化过」。
    /// 对应真实 AG 的 `Attribute.changedValue()`。
    func changedValue(of attribute: AnyAttribute) -> (Any, Bool) {
        let n = node(attribute)
        let value = self.value(of: attribute)
        guard let current = updateStack.last, let current else {
            return (value, true)
        }
        let consumer = nodes[current]
        guard let edge = consumer.inputs.first(where: { $0.node == n.id }) else {
            return (value, true)
        }
        // 还没完成过任何一次运行（没有旧值）时一律视为变化。
        return (value, consumer.value == nil || edge.seen != n.version)
    }

    private func recordDependency(on input: Node) {
        guard let top = updateStack.last, let consumerID = top else { return }
        precondition(consumerID != input.id, "检测到环：\(input.description) 读取了自己")
        let consumer = nodes[consumerID]
        if !consumer.inputSet.contains(input.id) {
            consumer.inputSet.insert(input.id)
            // seen = UInt64.max 保证首次运行后会被刷新成真实版本
            consumer.inputs.append((input.id, UInt64.max))
            input.outputs.insert(consumerID)
        }
    }

    /// 拉模式的核心：必要时重新计算一个节点。
    func updateIfNeeded(_ n: Node) {
        guard n.isValid, let _ = n.body else { return }
        guard n.isDirty || n.value == nil || n.forceRun else { return }
        precondition(!updateStack.contains(n.id), "检测到依赖环：\(n.description)")

        var needsRun = n.value == nil || n.forceRun
        if !needsRun {
            // 先把所有输入更新到最新，再看它们的版本号有没有变。
            for edge in n.inputs {
                let input = nodes[edge.node]
                guard input.isValid else { needsRun = true; continue }
                updateIfNeeded(input)
                if input.version != edge.seen { needsRun = true }
            }
        }
        n.isDirty = false
        n.forceRun = false
        if needsRun { run(n) }
    }

    private func run(_ n: Node) {
        guard let box = n.body else { return }
        ruleEvaluationCount += 1
        traceLog?.append(box.body._description)
        updateStack.append(n.id)
        box.body._update()
        updateStack.removeLast()
        precondition(n.value != nil, "规则 \(n.description) 运行后没有设置初始值")
        // 运行完毕：记录本次看到的各输入版本；顺便丢掉已失效的输入边。
        n.inputs = n.inputs.compactMap { edge in
            let input = nodes[edge.node]
            guard input.isValid else { n.inputSet.remove(edge.node); return nil }
            return (edge.node, input.version)
        }
    }

    // MARK: 写入（推）

    /// 规则在运行过程中设置自己的输出值（真实 AG：AGGraphSetOutputValue）。
    func setOutputValue(_ value: Any) {
        guard let top = updateStack.last, let id = top else {
            preconditionFailure("只能在规则运行期间设置输出值")
        }
        let n = nodes[id]
        if let old = n.value, compareValues(old, value) { return }
        n.value = value
        n.version &+= 1
    }

    func outputValue() -> Any? {
        guard let top = updateStack.last, let id = top else { return nil }
        return nodes[id].value
    }

    var currentAttribute: AnyAttribute? {
        guard let top = updateStack.last, let id = top else { return nil }
        return AnyAttribute(rawValue: id)
    }

    /// 外部写入一个 input 节点。返回值是否真的改变。
    @discardableResult
    func setValue(_ value: Any, of attribute: AnyAttribute) -> Bool {
        let n = node(attribute)
        precondition(n.body == nil, "只能直接写入 input 节点")
        if let old = n.value, compareValues(old, value) { return false }
        n.value = value
        n.version &+= 1
        propagateDirty(from: n)
        return true
    }

    /// 让节点被视为「变了」：用于 Void 类型的信号节点（State 的 signal）。
    func invalidateValue(of attribute: AnyAttribute) {
        let n = node(attribute)
        guard n.isValid else { return }
        n.version &+= 1
        if n.body != nil { n.forceRun = true; n.isDirty = true }
        propagateDirty(from: n)
    }

    /// 沿输出边把下游标脏。已经脏的节点其下游必然也已经脏，可以剪枝。
    func propagateDirty(from n: Node) {
        var stack = Array(n.outputs)
        while let id = stack.popLast() {
            let output = nodes[id]
            guard output.isValid, !output.isDirty else { continue }
            output.isDirty = true
            stack.append(contentsOf: output.outputs)
        }
    }

    func mutateBody<R>(_ attribute: AnyAttribute, as type: R.Type, invalidating: Bool, _ body: (inout R) -> Void) {
        let n = node(attribute)
        guard let box = n.body else { preconditionFailure("input 节点没有 body") }
        guard box.body._mutate(body) else { preconditionFailure("body 类型不是 \(R.self)") }
        if invalidating {
            n.forceRun = true
            n.isDirty = true
            propagateDirty(from: n)
        }
    }

    // MARK: 工具

    /// 在不记录依赖的情况下执行（真实 SwiftUI：Graph.withoutUpdate）。
    public func withoutUpdate<T>(_ body: () -> T) -> T {
        updateStack.append(nil)
        defer { updateStack.removeLast() }
        return body()
    }

    /// 记录 body 执行期间运行过的规则名，用于观察「到底重新算了什么」。
    public func trace(_ body: () -> Void) -> [String] {
        let saved = traceLog
        traceLog = []
        body()
        let log = traceLog ?? []
        traceLog = saved
        return log
    }

    public var liveNodeCount: Int { nodes.lazy.filter(\.isValid).count }
}

// MARK: - Subgraph

/// 节点的分组。销毁一个 Subgraph 会让其中所有节点失效 —— 这就是 SwiftUI 中
/// 「视图身份改变 → 状态被丢弃」的物理基础（if/else 分支切换、ForEach 删除元素、
/// AnyView 类型变化都会销毁旧 Subgraph、创建新 Subgraph）。
public final class Subgraph {
    public static var current: Subgraph?

    private(set) var nodes: [Node] = []
    private(set) var children: [Subgraph] = []
    public private(set) var isValid = true
    public let name: String

    public init(name: String = "subgraph") { self.name = name }

    func add(_ node: Node) {
        node.subgraph = self
        nodes.append(node)
    }

    public func addChild(_ child: Subgraph) { children.append(child) }

    /// 在这个 Subgraph 里创建节点。图的「构建期」不应读取任何值，所以这里也关闭依赖记录。
    public func apply<T>(_ body: () -> T) -> T {
        let old = Subgraph.current
        Subgraph.current = self
        defer { Subgraph.current = old }
        return Graph.shared.withoutUpdate(body)
    }

    public func invalidate() {
        guard isValid else { return }
        isValid = false
        for child in children { child.invalidate() }
        let graph = Graph.shared
        for node in nodes {
            graph.propagateDirty(from: node)
            node.isValid = false
            node.body = nil
            node.value = nil
            for edge in node.inputs { graph.nodes[edge.node].outputs.remove(node.id) }
        }
        nodes.removeAll()
        children.removeAll()
    }
}
