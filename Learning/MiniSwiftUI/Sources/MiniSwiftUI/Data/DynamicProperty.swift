// DynamicProperty.swift
//
// @State、@Environment、@Binding…… 这些属性包装器都遵守 DynamicProperty。
// 它们的共同点是：视图结构体本身是「用完即弃」的值，每次父视图 body 重算都会重新
// 创建；真正需要跨越多次 body 求值而保留的东西（状态存储、订阅……）必须放在图里。
//
// 真实 SwiftUI 的做法：
//   1. _makeView 时用 Swift 运行时元数据扫描视图类型的字段，找出所有 DynamicProperty
//      及其字节偏移（DynamicPropertyCache.fields(of:)）。
//   2. 为每个字段调用 `_makeProperty(in:container:fieldOffset:inputs:)`，在
//      _DynamicPropertyBuffer 中追加一个「盒子」（DynamicPropertyBox）。盒子存活在图里。
//   3. 如果一个 DynamicProperty 都没有，body 节点用 StaticBody（无状态 Rule）；
//      否则用 DynamicBody（StatefulRule），它持有这个 buffer。
//   4. 每次 DynamicBody 运行时，先让每个盒子 update(property:)：把图里的数据
//      「注入」到这一次新鲜的视图结构体的对应字段里（通过指针 + 偏移直接改写），
//      并报告数据是否变化；只要视图本身或任一盒子变化，才调用 body。
//
// MiniSwiftUI 的简化：
//   * 用 Mirror 扫描「实例」而非类型，所以扫描推迟到第一次运行 body 规则时进行。
//   * 不能安全地改写结构体字段，于是每个包装器里放一个 class 盒子（_link），
//     Mirror 拿到的副本与视图共享这个盒子，往盒子里写就等于「注入」。

public protocol DynamicProperty {
    /// 为这个属性创建图中的存储盒子。返回 nil 表示自身无存储
    /// （此时会继续扫描它内部嵌套的 DynamicProperty，例如自定义的属性包装器里包了 @State）。
    static func _makeProperty(inputs: _GraphInputs) -> (any DynamicPropertyBox)?
}

extension DynamicProperty {
    public static func _makeProperty(inputs: _GraphInputs) -> (any DynamicPropertyBox)? { nil }
}

/// 存活在图里的、某个 DynamicProperty 字段对应的状态（真实 SwiftUI 同名协议）。
public protocol DynamicPropertyBox {
    /// 把图中的数据注入到 `property`（视图字段的副本）中；返回数据是否变化。
    mutating func update(property: Any) -> Bool
}

/// 视图中所有 DynamicProperty 字段的盒子集合（真实：_DynamicPropertyBuffer）。
struct _DynamicPropertyBuffer {
    var entries: [(path: [Int], box: any DynamicPropertyBox)] = []

    init(scanning container: Any, inputs: _GraphInputs) {
        scan(container, path: [], inputs: inputs)
    }

    private mutating func scan(_ value: Any, path: [Int], inputs: _GraphInputs) {
        for (index, child) in Mirror(reflecting: value).children.enumerated() {
            guard let property = child.value as? any DynamicProperty else { continue }
            if let box = type(of: property)._makeProperty(inputs: inputs) {
                entries.append((path + [index], box))
            } else {
                scan(property, path: path + [index], inputs: inputs)
            }
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// 对一份新的视图值逐个更新盒子；任一盒子变化则返回 true。
    mutating func update(container: Any) -> Bool {
        var changed = false
        for i in entries.indices {
            let property = Self.child(of: container, at: entries[i].path)
            if entries[i].box.update(property: property) { changed = true }
        }
        return changed
    }

    private static func child(of value: Any, at path: [Int]) -> Any {
        var current = value
        for index in path {
            let children = Mirror(reflecting: current).children
            current = children[children.index(children.startIndex, offsetBy: index)].value
        }
        return current
    }
}
