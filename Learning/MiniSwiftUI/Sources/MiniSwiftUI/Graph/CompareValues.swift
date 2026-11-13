// CompareValues.swift
//
// 「新值和旧值是否相等」是增量计算能截断传播的关键。
//
// 真实 AG 的 compareValues（AGCompareValues）不要求类型实现 Equatable：它借助
// Swift 运行时的类型元数据（metadata）为每个类型生成一份「比较布局」
// (LayoutDescriptor)：POD 字段直接 memcmp，Equatable 字段调用 ==，类引用比较指针，
// 闭包等无法比较的字段则视为不相等。也正因为如此，SwiftUI 的 View 结构体不需要
// 遵守 Equatable 就能被比较。
//
// 这里用 Swift 的 Mirror 反射近似实现同样的策略。

/// 判断两个值是否「相同」。返回 false 表示无法证明相同（会被当作变化）。
public func compareValues<T>(_ lhs: T, _ rhs: T) -> Bool {
    _compareAny(lhs, rhs)
}

private extension Equatable {
    func _isEqual(to other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

func _compareAny(_ lhs: Any, _ rhs: Any) -> Bool {
    // 1. Equatable：直接用 ==
    if let l = lhs as? any Equatable {
        return l._isEqual(to: rhs)
    }
    // 2. 元类型：比较类型身份
    if let l = lhs as? Any.Type, let r = rhs as? Any.Type {
        return ObjectIdentifier(l) == ObjectIdentifier(r)
    }
    let lm = Mirror(reflecting: lhs)
    let rm = Mirror(reflecting: rhs)
    guard lm.subjectType == rm.subjectType else { return false }
    switch lm.displayStyle {
    case .class?:
        // 3. 引用类型：比较指针
        return (lhs as AnyObject) === (rhs as AnyObject)
    case .struct?, .tuple?:
        // 4. 结构体/元组：逐字段比较
        return _compareChildren(lm, rm)
    case .optional?, .enum?:
        // 5. 枚举：先比较 case，再比较关联值
        let lc = Array(lm.children), rc = Array(rm.children)
        guard lc.count == rc.count else { return false }
        if lc.isEmpty { return String(describing: lhs) == String(describing: rhs) }
        return zip(lc, rc).allSatisfy { $0.label == $1.label && _compareAny($0.value, $1.value) }
    case .collection?, .set?, .dictionary?:
        return _compareChildren(lm, rm)
    default:
        // 6. 闭包等：无法比较，保守地认为「变了」
        return false
    }
}

private func _compareChildren(_ lm: Mirror, _ rm: Mirror) -> Bool {
    let lc = Array(lm.children), rc = Array(rm.children)
    guard lc.count == rc.count else { return false }
    return zip(lc, rc).allSatisfy { _compareAny($0.value, $1.value) }
}
