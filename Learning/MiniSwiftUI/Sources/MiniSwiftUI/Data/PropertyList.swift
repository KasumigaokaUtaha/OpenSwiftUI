// PropertyList.swift
//
// EnvironmentValues 和 Transaction 在真实 SwiftUI 里都是对 PropertyList 的包装。
// PropertyList 是一个「不可变单向链表」：写入一个 key 不会修改原链表，而是在表头
// 前插一个新元素（新值遮蔽旧值）。这样做的好处：
//   * 父子视图共享同一段链表尾部，写环境几乎零拷贝；
//   * 比较两个 PropertyList 是否相同，只需比较表头指针是否相同（O(1)）。
// 真实实现见 OpenSwiftUICore/Data/Util/PropertyList.swift（还有 Tracker、BloomFilter 等优化）。

public protocol PropertyKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct PropertyList: CustomStringConvertible {
    final class Element {
        let keyType: Any.Type
        let value: Any
        let next: Element?
        init(keyType: Any.Type, value: Any, next: Element?) {
            self.keyType = keyType
            self.value = value
            self.next = next
        }
    }

    /// 表头。因为 Element 是 class，compareValues 会按指针比较它。
    var elements: Element?

    public init() {}

    public subscript<K: PropertyKey>(key: K.Type) -> K.Value {
        get {
            var e = elements
            while let current = e {
                if current.keyType == key { return current.value as! K.Value }
                e = current.next
            }
            return K.defaultValue
        }
        set {
            elements = Element(keyType: key, value: newValue, next: elements)
        }
    }

    public var description: String {
        var parts: [String] = []
        var e = elements
        while let current = e {
            parts.append("\(current.keyType) = \(current.value)")
            e = current.next
        }
        return "[" + parts.joined(separator: ", ") + "]"
    }
}
