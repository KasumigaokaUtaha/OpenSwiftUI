// State.swift
//
// @State 的完整生命周期（与真实 SwiftUI 的 State / StatePropertyBox / StoredLocation 对应）：
//
//   安装：DynamicBody 第一次运行时为 @State 字段创建 StatePropertyBox，其中包含一个
//         Void 类型的「signal」节点；body 规则读取 signal，从而依赖它。
//   首次求值：盒子创建 StoredLocation（真正的存储，一个 class），注入到视图的 State 里。
//   写入：`count += 1` → StoredLocation.set：
//         · 立即更新 currentValue（所以在同一个闭包里马上读能读到新值）；
//         · 捕获当前 Transaction，向宿主排队一个异步事务（asyncTransaction）。
//   刷新：宿主 flushTransactions → 执行事务：updateValue = currentValue，
//         并让 signal 失效（invalidateValue）→ 推脏到 body 规则。
//   重算：body 规则被拉取时，StatePropertyBox.update 发现 signal 变了；如果这个状态
//         在上次 body 中「被读过」（wasRead），就报告变化，body 重新计算。

@propertyWrapper
public struct State<Value>: DynamicProperty {
    let _initialValue: Value
    let _link = _StateLink<Value>()

    public init(wrappedValue value: Value) { _initialValue = value }
    public init(initialValue value: Value) { _initialValue = value }

    public var wrappedValue: Value {
        get {
            guard let location = _link.location else { return _initialValue }
            if Graph.shared.isUpdating {
                // body 求值期间读取：返回这一帧注入的值，并记下「被读过」。
                location.wasRead = true
                return _link.bodyValue ?? location.updateValue
            }
            return location.currentValue
        }
        nonmutating set {
            guard let location = _link.location else {
                print("⚠️ 在视图安装之前修改 @State 不会生效")
                return
            }
            location.set(newValue)
        }
    }

    public var projectedValue: Binding<Value> {
        guard let location = _link.location else { return .constant(_initialValue) }
        return Binding(get: { location.currentValue }, set: { location.set($0) })
    }

    public static func _makeProperty(inputs: _GraphInputs) -> (any DynamicPropertyBox)? {
        StatePropertyBox<Value>(signal: Attribute(value: ()))
    }
}

final class _StateLink<Value> {
    var location: StoredLocation<Value>?
    var bodyValue: Value?
}

/// 状态的真实存储。它是 class：视图结构体被反复重建，但它一直活在盒子里。
final class StoredLocation<Value> {
    var currentValue: Value
    var updateValue: Value
    var wasRead = false
    weak var host: ViewGraph?
    let signal: Attribute<Void>

    init(initialValue: Value, host: ViewGraph?, signal: Attribute<Void>) {
        currentValue = initialValue
        updateValue = initialValue
        self.host = host
        self.signal = signal
    }

    func set(_ newValue: Value) {
        guard !Graph.shared.isUpdating else {
            print("⚠️ Modifying state during view update, this will cause undefined behavior.")
            return
        }
        guard Graph.shared.node(signal.identifier).isValid else { return }
        if compareValues(currentValue, newValue) { return }
        currentValue = newValue
        host?.asyncTransaction(Transaction.current) { [self] in
            updateValue = currentValue
            signal.invalidateValue()
        }
    }
}

struct StatePropertyBox<Value>: DynamicPropertyBox {
    let signal: Attribute<Void>
    var location: StoredLocation<Value>?

    mutating func update(property: Any) -> Bool {
        let state = property as! State<Value>
        var changed = false
        if location == nil {
            location = StoredLocation(initialValue: state._initialValue, host: ViewGraph.current, signal: signal)
            changed = true
        }
        let location = location!
        let (_, signalChanged) = signal.changedValue()
        if signalChanged, !changed {
            // 优化：如果 body 上次根本没读这个状态，它的变化不需要触发 body 重算。
            changed = location.wasRead
        }
        state._link.location = location
        state._link.bodyValue = location.updateValue
        return changed
    }
}

// MARK: - Binding

/// 双向绑定：一对 get/set。真实 SwiftUI 的 Binding 包含一个 AnyLocation 和一个 Transaction。
@propertyWrapper
@dynamicMemberLookup
public struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }

    public var projectedValue: Binding<Value> { self }

    public subscript<Member>(dynamicMember keyPath: WritableKeyPath<Value, Member>) -> Binding<Member> {
        Binding<Member>(
            get: { self.get()[keyPath: keyPath] },
            set: { newValue in
                var value = self.get()
                value[keyPath: keyPath] = newValue
                self.set(value)
            }
        )
    }
}

// Binding 本身没有图中的存储，但为了让包含 @Binding 的视图被正确扫描，这里也遵守协议。
extension Binding: DynamicProperty {}
