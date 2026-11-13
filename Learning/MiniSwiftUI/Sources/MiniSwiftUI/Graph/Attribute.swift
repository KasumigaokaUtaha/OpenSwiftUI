// Attribute.swift
//
// 对应真实框架中 AttributeGraph 暴露给 Swift 的 API：
//   Attribute<Value>、Rule、StatefulRule、OptionalAttribute、WeakAttribute……
// 真实定义见 OpenAttributeGraph/Sources/OpenAttributeGraph/Attribute/*。

/// 一个强类型的图节点引用。它本身只是一个整数 ID，复制它不会复制节点。
///
/// 作为 property wrapper 使用时（`@Attribute var size: Size`），在规则内部读取
/// `size` 就会自动拉取最新值并记录依赖边 —— 这正是真实 SwiftUI 源码中随处可见的写法。
@propertyWrapper
@dynamicMemberLookup
public struct Attribute<Value>: Equatable, CustomStringConvertible {
    public let identifier: AnyAttribute

    public init(identifier: AnyAttribute) { self.identifier = identifier }

    /// 外部输入节点。
    public init(value: Value) {
        identifier = Graph.shared.makeNode(valueType: Value.self, body: nil, value: value)
    }

    /// 由无状态规则计算的节点。
    public init<R: Rule>(_ rule: R) where R.Value == Value {
        identifier = Graph.shared.makeNode(valueType: Value.self, body: _RuleAdapter(rule: rule), value: nil)
    }

    /// 由有状态规则计算的节点。
    public init<R: StatefulRule>(_ rule: R) where R.Value == Value {
        identifier = Graph.shared.makeNode(valueType: Value.self, body: _StatefulRuleAdapter(rule: rule), value: nil)
    }

    public var value: Value {
        get { Graph.shared.value(of: identifier) as! Value }
        nonmutating set { Graph.shared.setValue(newValue, of: identifier) }
    }

    public var wrappedValue: Value {
        get { value }
        nonmutating set { value = newValue }
    }

    public var projectedValue: Attribute<Value> { self }

    public init(projectedValue: Attribute<Value>) { self = projectedValue }

    @discardableResult
    public func setValue(_ value: Value) -> Bool {
        Graph.shared.setValue(value, of: identifier)
    }

    /// 读取值，并返回它自当前规则上次运行以来是否变化。
    public func changedValue() -> (value: Value, changed: Bool) {
        let (value, changed) = Graph.shared.changedValue(of: identifier)
        return (value as! Value, changed)
    }

    public func invalidateValue() { Graph.shared.invalidateValue(of: identifier) }

    /// 修改一个已经创建好的规则节点的 body（真实 AG：Attribute.mutateBody）。
    /// SwiftUI 常用它解决「先有鸡还是先有蛋」：先建父节点，建完子节点后再把子节点塞回去。
    public func mutateBody<R>(as type: R.Type, invalidating: Bool, _ body: (inout R) -> Void) {
        Graph.shared.mutateBody(identifier, as: type, invalidating: invalidating, body)
    }

    /// 投影：派生出一个读取 `value[keyPath:]` 的新节点。
    /// 真实 AG 用「偏移 attribute」（同一节点 + 字节偏移）实现，几乎零开销；这里简化为新建一个规则节点。
    public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Attribute<Member> {
        self[keyPath: keyPath]
    }

    public subscript<Member>(keyPath keyPath: KeyPath<Value, Member>) -> Attribute<Member> {
        Attribute<Member>(Focus(base: self, keyPath: keyPath))
    }

    public func map<T>(_ name: String = "Map", _ transform: @escaping (Value) -> T) -> Attribute<T> {
        Attribute<T>(MapRule(source: self, transform: transform, name: name))
    }

    public var description: String { "\(identifier)" }
}

/// 无状态规则：值完全由 `value` 计算属性决定。
public protocol Rule {
    associatedtype Value
    var value: Value { get }
}

/// 有状态规则：自己可以保存跨次运行的状态（它是 struct，被图持有并就地修改），
/// 并通过 `value` 读写自己的输出。
public protocol StatefulRule {
    associatedtype Value
    mutating func updateValue()
}

extension StatefulRule {
    /// 当前输出值（只能在 updateValue 里访问）。
    public var value: Value {
        get {
            guard let v = Graph.shared.outputValue() else { preconditionFailure("尚无值，先检查 hasValue") }
            return v as! Value
        }
        nonmutating set { Graph.shared.setOutputValue(newValue) }
    }

    public var hasValue: Bool { Graph.shared.outputValue() != nil }

    /// 正在运行的这个节点自身。
    public var attribute: Attribute<Value> {
        Attribute(identifier: Graph.shared.currentAttribute!)
    }
}

struct _RuleAdapter<R: Rule>: _AnyRuleBody {
    var rule: R
    mutating func _mutate<T>(_ body: (inout T) -> Void) -> Bool {
        guard var r = rule as? T else { return false }
        body(&r)
        rule = r as! R
        return true
    }
    mutating func _update() { Graph.shared.setOutputValue(rule.value) }
    var _description: String { _ruleName(rule) }
}

struct _StatefulRuleAdapter<R: StatefulRule>: _AnyRuleBody {
    var rule: R
    mutating func _mutate<T>(_ body: (inout T) -> Void) -> Bool {
        guard var r = rule as? T else { return false }
        body(&r)
        rule = r as! R
        return true
    }
    mutating func _update() { rule.updateValue() }
    var _description: String { _ruleName(rule) }
}

func _ruleName(_ rule: Any) -> String {
    if let custom = rule as? CustomStringConvertible { return custom.description }
    return String(describing: type(of: rule)).split(separator: ".").last.map(String.init) ?? "Rule"
}

struct Focus<Base, Member>: Rule, CustomStringConvertible {
    @Attribute var base: Base
    let keyPath: KeyPath<Base, Member>
    var value: Member { base[keyPath: keyPath] }
    var description: String { "Focus<\(Member.self)>" }
}

struct MapRule<Source, Value>: Rule, CustomStringConvertible {
    @Attribute var source: Source
    let transform: (Source) -> Value
    let name: String
    var value: Value { transform(source) }
    var description: String { name }
}

/// 可能不存在的 attribute（真实 SwiftUI 大量使用，例如 _ViewOutputs.layoutComputer）。
public struct OptionalAttribute<Value> {
    public var attribute: Attribute<Value>?
    public init(_ attribute: Attribute<Value>? = nil) { self.attribute = attribute }
    public var value: Value? { attribute?.value }
}
