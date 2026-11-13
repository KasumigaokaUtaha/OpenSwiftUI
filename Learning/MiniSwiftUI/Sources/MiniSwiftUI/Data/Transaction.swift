// Transaction.swift
//
// Transaction 描述「这一次状态变化应该如何被呈现」，最重要的字段就是 animation。
//
// 流程（与真实 SwiftUI 一致）：
//   withAnimation { state = x }
//     → State 的 setter 记下当前线程上的 Transaction（带 animation）
//     → GraphHost.asyncTransaction(transaction, mutation) 把「写 signal」这个修改排队
//     → 宿主刷新时 flushTransactions：先把 transaction 写进图的 transaction 输入节点，
//       再执行修改、更新图；图中的 AnimatableAttribute 读到 transaction.animation，
//       于是开始插值而不是直接跳到新值。

struct AnimationKey: PropertyKey { static let defaultValue: Animation? = nil }
struct DisablesAnimationsKey: PropertyKey { static let defaultValue = false }

public struct Transaction: CustomStringConvertible {
    var plist = PropertyList()

    public init() {}
    public init(animation: Animation?) { self.animation = animation }

    public var animation: Animation? {
        get { plist[AnimationKey.self] }
        set { plist[AnimationKey.self] = newValue }
    }

    public var disablesAnimations: Bool {
        get { plist[DisablesAnimationsKey.self] }
        set { plist[DisablesAnimationsKey.self] = newValue }
    }

    var isEmpty: Bool { plist.elements == nil }

    public var description: String { "Transaction\(plist)" }

    /// 当前线程上的 Transaction（真实 SwiftUI：Transaction._current / threadTransactionData）。
    static var current = Transaction()
}

public func withTransaction<R>(_ transaction: Transaction, _ body: () throws -> R) rethrows -> R {
    let old = Transaction.current
    Transaction.current = transaction
    defer { Transaction.current = old }
    return try body()
}

public func withAnimation<R>(_ animation: Animation? = .default, _ body: () throws -> R) rethrows -> R {
    var transaction = Transaction.current
    transaction.animation = animation
    return try withTransaction(transaction, body)
}
