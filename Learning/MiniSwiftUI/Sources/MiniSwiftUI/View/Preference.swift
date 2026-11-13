// Preference.swift
//
// 偏好（Preference）是与环境方向相反的数据流：子视图 → 祖先。
//
//   * 祖先在 inputs.preferenceKeys 里声明「我想要 K」；
//   * 写入 K 的视图在 outputs 里放一个 K 的节点；
//   * 容器视图把所有孩子的 K 用 K.reduce 合并成一个节点（真实：PreferenceCombiner）；
//   * 读取方（onPreferenceChange、宿主）在更新结束后取最终值。
//
// 一个重要的事实：SwiftUI 的显示列表（DisplayList，即「要画什么」）本身就是一种偏好
// （DisplayList.Key），由叶子视图产生，沿着视图树向上合并，最后到达宿主。

public protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}

public struct PreferenceKeys {
    var types: [any PreferenceKey.Type] = []

    public init() {}

    public func contains<K: PreferenceKey>(_ key: K.Type) -> Bool {
        types.contains { $0 == key }
    }

    public mutating func add<K: PreferenceKey>(_ key: K.Type) {
        if !contains(key) { types.append(key) }
    }
}

/// 把多个孩子的偏好合并。只合并祖先要求的 key。
func combinePreferences(_ children: [_ViewOutputs], keys: PreferenceKeys) -> _ViewOutputs {
    var outputs = _ViewOutputs()
    for key in keys.types {
        func combine<K: PreferenceKey>(_: K.Type) {
            let values = children.compactMap { $0[K.self] }
            switch values.count {
            case 0: break
            case 1: outputs[K.self] = values[0]
            default: outputs[K.self] = Attribute(PreferenceCombiner<K>(children: values))
            }
        }
        combine(key)
    }
    return outputs
}

struct PreferenceCombiner<K: PreferenceKey>: Rule, CustomStringConvertible {
    let children: [Attribute<K.Value>]
    var value: K.Value {
        var result = K.defaultValue
        var first = true
        for child in children {
            if first { result = child.value; first = false; continue }
            K.reduce(value: &result) { child.value }
        }
        return result
    }
    var description: String { "PreferenceCombiner<\(K.self)>" }
}

// MARK: - .preference(key:value:)

public struct _PreferenceWritingModifier<K: PreferenceKey>: _PrimitiveViewModifier {
    public var value: K.Value

    public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        var outputs = body(inputs)
        if inputs.preferenceKeys.contains(K.self) {
            outputs[K.self] = modifier.value.map("PreferenceWriter<\(K.self)>") { $0.value }
        }
        return outputs
    }
}

// MARK: - .onPreferenceChange

public struct _PreferenceActionModifier<K: PreferenceKey>: _PrimitiveViewModifier where K.Value: Equatable {
    public var action: (K.Value) -> Void

    public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        var childInputs = inputs
        childInputs.preferenceKeys.add(K.self) // 向子树「订阅」K
        let outputs = body(childInputs)
        let observer = Attribute(PreferenceObserver<K>(
            modifier: modifier.value,
            preference: outputs[K.self] ?? Attribute(value: K.defaultValue)
        ))
        ViewGraph.current?.addObserver(observer.identifier)
        return outputs
    }
}

/// 值变化时，把回调排进「更新结束后执行」的队列 —— 在图更新期间直接改状态是不允许的。
struct PreferenceObserver<K: PreferenceKey>: StatefulRule, CustomStringConvertible where K.Value: Equatable {
    typealias Value = Void
    @Attribute var modifier: _PreferenceActionModifier<K>
    @Attribute var preference: K.Value
    var lastValue: K.Value?

    mutating func updateValue() {
        let newValue = preference
        if lastValue != newValue {
            lastValue = newValue
            let action = modifier.action
            ViewGraph.current?.enqueuePostUpdateAction { action(newValue) }
        }
        if !hasValue { value = () }
    }

    var description: String { "PreferenceObserver<\(K.self)>" }
}

extension View {
    public func preference<K: PreferenceKey>(key: K.Type = K.self, value: K.Value) -> some View {
        modifier(_PreferenceWritingModifier<K>(value: value))
    }

    public func onPreferenceChange<K: PreferenceKey>(
        _ key: K.Type = K.self,
        perform action: @escaping (K.Value) -> Void
    ) -> some View where K.Value: Equatable {
        modifier(_PreferenceActionModifier<K>(action: action))
    }
}
