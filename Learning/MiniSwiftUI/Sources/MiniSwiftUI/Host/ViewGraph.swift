// ViewGraph.swift
//
// 宿主与图之间的桥梁。真实 SwiftUI 中分两层：
//   * GraphHost：持有图的「全局输入」（time、environment、transaction、phase……），
//     管理事务队列（asyncTransaction / flushTransactions / runTransaction）。
//   * ViewGraph（GraphHost 的子类）：持有根视图节点、根几何、根输出
//     （rootDisplayList、rootLayoutComputer、偏好……），提供 updateOutputs(at:)。
// 见 OpenSwiftUICore/Graph/GraphHost.swift 与 OpenSwiftUICore/View/Graph/ViewGraph.swift。

public final class ViewGraph {
    /// 当前正在更新/构建的 ViewGraph（真实：ViewGraph.current / GraphHost.currentHost）。
    public internal(set) static var current: ViewGraph?
    static let frameInterval = 1.0 / 10.0

    let rootSubgraph: Subgraph
    let environment: Attribute<EnvironmentValues>
    let transaction: Attribute<Transaction>
    let time: Attribute<Double>
    let hostSize: Attribute<Size>
    let rootGeometry: Attribute<ViewGeometry>
    private(set) var rootDisplayList: Attribute<DisplayList>!
    private(set) var rootLayoutComputer: Attribute<LayoutComputer>?
    private let rootViewAttribute: AnyAttribute

    private var pendingTransactions: [(transaction: Transaction, mutations: [() -> Void])] = []
    private var observers: [AnyAttribute] = []
    private var postUpdateActions: [() -> Void] = []

    /// 动画等请求的下一次更新时间。
    public private(set) var nextUpdateTime: Double?
    /// 图「需要更新」时的回调（真实：GraphDelegate.graphDidChange → 宿主 setNeedsUpdate）。
    public var onNeedsUpdate: (() -> Void)?

    public init<Root: View>(rootView: Root, size: Size, environment: EnvironmentValues = EnvironmentValues()) {
        let old = ViewGraph.current
        defer { ViewGraph.current = old }

        // 1. 在根子图里创建宿主提供的全局输入节点。
        let subgraph = Subgraph(name: "root")
        let env = subgraph.apply { Attribute(value: environment) }
        let transaction = subgraph.apply { Attribute(value: Transaction()) }
        let time = subgraph.apply { Attribute(value: 0.0) }
        let hostSize = subgraph.apply { Attribute(value: size) }
        let rootGeometry = subgraph.apply { Attribute(RootGeometry(hostSize: hostSize, child: nil)) }
        let rootAttribute = subgraph.apply { Attribute(value: rootView) }
        rootSubgraph = subgraph
        self.environment = env
        self.transaction = transaction
        self.time = time
        self.hostSize = hostSize
        self.rootGeometry = rootGeometry
        rootViewAttribute = rootAttribute.identifier

        // 2. 调用根视图的 _makeView，递归地把整棵视图树「安装」进图。
        ViewGraph.current = self
        let outputs = subgraph.apply { () -> _ViewOutputs in
            var inputs = _ViewInputs(
                base: _GraphInputs(environment: env, transaction: transaction, time: time),
                position: rootGeometry.origin,
                size: rootGeometry.size
            )
            inputs.preferenceKeys.add(DisplayList.Key.self) // 宿主想要显示列表
            return Root._makeView(view: _GraphValue(rootAttribute), inputs: inputs)
        }

        // 3. 记录根输出；根几何依赖根视图的布局。
        rootLayoutComputer = outputs.layoutComputer
        rootGeometry.mutateBody(as: RootGeometry.self, invalidating: true) { $0.child = outputs.layoutComputer }
        rootDisplayList = outputs[DisplayList.Key.self] ?? subgraph.apply { Attribute(value: DisplayList()) }
    }

    // MARK: 根输入

    public func setRootView<Root: View>(_ view: Root) {
        if Attribute<Root>(identifier: rootViewAttribute).setValue(view) { onNeedsUpdate?() }
    }

    public func setSize(_ size: Size) {
        if hostSize.setValue(size) { onNeedsUpdate?() }
    }

    public func setEnvironment(_ environment: EnvironmentValues) {
        if self.environment.setValue(environment) { onNeedsUpdate?() }
    }

    // MARK: 事务

    /// 把一次图修改排队（真实：GraphHost.asyncTransaction）。同一个 Transaction 下的修改会合并。
    func asyncTransaction(_ transaction: Transaction, _ mutation: @escaping () -> Void) {
        if let last = pendingTransactions.indices.last,
           compareValues(pendingTransactions[last].transaction, transaction) {
            pendingTransactions[last].mutations.append(mutation)
        } else {
            pendingTransactions.append((transaction, [mutation]))
        }
        onNeedsUpdate?()
    }

    public var hasPendingTransactions: Bool { !pendingTransactions.isEmpty }

    private func flushTransactions() {
        let pending = pendingTransactions
        pendingTransactions = []
        for (transaction, mutations) in pending {
            // runTransaction：先设置 transaction 输入，再执行修改，再在这个 transaction 下更新图。
            self.transaction.setValue(transaction)
            for mutation in mutations { mutation() }
            pullOutputs()
            self.transaction.setValue(Transaction())
        }
    }

    func requestUpdate(at time: Double) {
        nextUpdateTime = min(nextUpdateTime ?? .infinity, time)
    }

    func addObserver(_ attribute: AnyAttribute) { observers.append(attribute) }

    func enqueuePostUpdateAction(_ action: @escaping () -> Void) { postUpdateActions.append(action) }

    private func pullOutputs() {
        _ = rootDisplayList.value
        for observer in observers where Graph.shared.node(observer).isValid {
            _ = Graph.shared.value(of: observer)
        }
    }

    // MARK: 更新

    /// 把图更新到 `time` 时刻，返回最新的显示列表（真实：ViewGraph.updateOutputs(at:)）。
    @discardableResult
    public func update(at time: Double) -> DisplayList {
        let old = ViewGraph.current
        ViewGraph.current = self
        defer { ViewGraph.current = old }

        self.time.setValue(time)
        nextUpdateTime = nil
        var counter = 0
        repeat {
            counter += 1
            flushTransactions()
            pullOutputs()
            // onPreferenceChange 等回调在图更新结束后执行，它们可能又修改了状态。
            let actions = postUpdateActions
            postUpdateActions = []
            actions.forEach { $0() }
        } while hasPendingTransactions && counter < 8
        return rootDisplayList.value
    }

    public var rootSize: Size { rootGeometry.value.size }
}

/// 根几何：把宿主尺寸作为提议交给根视图，再把结果居中放在宿主里（真实：RootGeometry）。
struct RootGeometry: Rule, CustomStringConvertible {
    @Attribute var hostSize: Size
    var child: Attribute<LayoutComputer>?

    var value: ViewGeometry {
        let host = hostSize
        let size = (child?.value ?? .default).sizeThatFits(ProposedSize(host))
        let origin = Point(x: ((host.width - size.width) / 2).rounded(.down), y: ((host.height - size.height) / 2).rounded(.down))
        return ViewGeometry(origin: origin, size: size)
    }
    var description: String { "RootGeometry" }
}
