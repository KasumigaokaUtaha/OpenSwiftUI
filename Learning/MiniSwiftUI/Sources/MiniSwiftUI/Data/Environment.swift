// Environment.swift
//
// 环境（Environment）的实现原理：
//   * _GraphInputs 里有一个 `environment: Attribute<EnvironmentValues>`，随 _makeView
//     一路向下传递给所有子视图（真实 SwiftUI：_GraphInputs.environment）。
//   * `.environment(\.key, value)` 修饰符在 _makeView 时创建一个新的 ChildEnvironment
//     规则节点，替换掉子视图 inputs 里的 environment（真实：_EnvironmentKeyWritingModifier）。
//   * `@Environment(\.key)` 是一个 DynamicProperty：它在 body 求值前读取环境，并只在
//     「它关心的那个 key 的值变化」时才让 body 重新计算（真实：EnvironmentBox）。

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

struct EnvironmentPropertyKey<K: EnvironmentKey>: PropertyKey {
    static var defaultValue: K.Value { K.defaultValue }
}

public struct EnvironmentValues: CustomStringConvertible {
    var plist = PropertyList()
    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { plist[EnvironmentPropertyKey<K>.self] }
        set { plist[EnvironmentPropertyKey<K>.self] = newValue }
    }

    public var description: String { plist.description }
}

// MARK: - 内置的几个环境值

public enum TextCase { case uppercase, lowercase }

struct TextCaseKey: EnvironmentKey { static let defaultValue: TextCase? = nil }
struct ForegroundFillKey: EnvironmentKey { static let defaultValue: Character? = nil }

extension EnvironmentValues {
    /// 文本大小写变换（真实 SwiftUI 同名 API）。
    public var textCase: TextCase? {
        get { self[TextCaseKey.self] }
        set { self[TextCaseKey.self] = newValue }
    }

    /// 控制台渲染时 Color 默认使用的填充字符。
    public var foregroundFill: Character? {
        get { self[ForegroundFillKey.self] }
        set { self[ForegroundFillKey.self] = newValue }
    }
}

// MARK: - .environment(_:_:) 修饰符

public struct _EnvironmentKeyWritingModifier<Value>: ViewModifier, _PrimitiveViewModifier {
    public var keyPath: WritableKeyPath<EnvironmentValues, Value>
    public var value: Value

    public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        var inputs = inputs
        inputs.base.environment = Attribute(ChildEnvironment(modifier: modifier.value, parent: inputs.base.environment))
        return body(inputs)
    }
}

/// 子环境 = 父环境 + 一次写入。
/// 如果父环境没变、修饰符的值也没变，就保留旧的 EnvironmentValues（同一个链表头指针），
/// 下游比较时会发现「没变」，从而不必重新计算。
struct ChildEnvironment<KeyValue>: StatefulRule, CustomStringConvertible {
    typealias Value = EnvironmentValues
    @Attribute var modifier: _EnvironmentKeyWritingModifier<KeyValue>
    @Attribute var parent: EnvironmentValues

    mutating func updateValue() {
        let (modifier, modifierChanged) = $modifier.changedValue()
        let (parent, parentChanged) = $parent.changedValue()
        if hasValue, !parentChanged {
            guard modifierChanged else { return }
            if compareValues(value[keyPath: modifier.keyPath], modifier.value) { return }
        }
        var env = parent
        env[keyPath: modifier.keyPath] = modifier.value
        value = env
    }

    var description: String { "ChildEnvironment<\(KeyValue.self)>" }
}

extension View {
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View {
        modifier(_EnvironmentKeyWritingModifier(keyPath: keyPath, value: value))
    }

    public func textCase(_ textCase: TextCase?) -> some View {
        environment(\.textCase, textCase)
    }
}

// MARK: - @Environment

@propertyWrapper
public struct Environment<Value>: DynamicProperty {
    let keyPath: KeyPath<EnvironmentValues, Value>
    /// 真实 SwiftUI 中 Environment 是一个 enum（.keyPath / .value），DynamicProperty
    /// 系统会通过字段偏移直接把解析后的值写回视图结构体。我们无法安全地改写结构体
    /// 字段，于是用一个 class 盒子承载「被注入的值」。
    let _box = _EnvironmentStorage<Value>()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { self.keyPath = keyPath }

    public var wrappedValue: Value {
        guard let value = _box.value else {
            preconditionFailure("在视图被安装到图中之前访问了 @Environment")
        }
        return value
    }

    public static func _makeProperty(inputs: _GraphInputs) -> (any DynamicPropertyBox)? {
        EnvironmentBox<Value>(environment: inputs.environment)
    }
}

final class _EnvironmentStorage<Value> {
    var value: Value?
}

struct EnvironmentBox<Value>: DynamicPropertyBox {
    @Attribute var environment: EnvironmentValues
    var keyPath: KeyPath<EnvironmentValues, Value>?
    var value: Value?

    init(environment: Attribute<EnvironmentValues>) { _environment = environment }

    mutating func update(property: Any) -> Bool {
        let property = property as! Environment<Value>
        let (env, envChanged) = $environment.changedValue()
        var changed = false
        if envChanged || keyPath != property.keyPath || value == nil {
            let newValue = env[keyPath: property.keyPath]
            if let old = value, keyPath == property.keyPath, compareValues(old, newValue) {
                // 环境整体变了，但我关心的那个值没变 —— body 不需要重算。
            } else {
                changed = true
            }
            value = newValue
            keyPath = property.keyPath
        }
        property._box.value = value
        return changed
    }
}
