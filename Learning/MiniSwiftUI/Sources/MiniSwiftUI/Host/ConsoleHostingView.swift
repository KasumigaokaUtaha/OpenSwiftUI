// ConsoleHostingView.swift
//
// 一个把 SwiftUI 视图「托管」到控制台的宿主，地位相当于 UIHostingView/NSHostingView
// （或 OpenSwiftUI 在 Linux 上的 StdoutRendererHost）：
//   * 持有 ViewGraph；
//   * 驱动更新：update(at: time) → 拿到显示列表 → 交给渲染器；
//   * 把输入事件（点击）路由到显示列表里的可点击目标。

public final class ConsoleHostingView<Root: View> {
    public let viewGraph: ViewGraph
    public private(set) var size: Size
    public private(set) var time: Double = 0
    public private(set) var lastDisplayList = DisplayList()

    public init(rootView: Root, width: Int, height: Int) {
        size = Size(width: Double(width), height: Double(height))
        viewGraph = ViewGraph(rootView: rootView, size: size)
    }

    /// 替换根视图的值（相当于 UIHostingController.rootView = ...）。
    public func setRootView(_ rootView: Root) {
        viewGraph.setRootView(rootView)
    }

    public func setSize(width: Int, height: Int) {
        size = Size(width: Double(width), height: Double(height))
        viewGraph.setSize(size)
    }

    /// 更新图并渲染出一帧。
    @discardableResult
    public func render(at time: Double? = nil) -> String {
        if let time { self.time = time }
        lastDisplayList = viewGraph.update(at: self.time)
        return ConsoleRenderer(width: Int(size.width), height: Int(size.height)).render(lastDisplayList)
    }

    /// 带边框的渲染结果，便于在终端里看清边界。
    public func renderFramed(at time: Double? = nil) -> String {
        let body = render(at: time)
        let w = Int(size.width)
        let border = "+" + String(repeating: "-", count: w) + "+"
        return ([border] + body.split(separator: "\n", omittingEmptySubsequences: false).map { "|\($0)|" } + [border])
            .joined(separator: "\n")
    }

    /// 动画请求的下一帧时间。
    public var nextUpdateTime: Double? { viewGraph.nextUpdateTime }

    /// 点击某个坐标。
    @discardableResult
    public func tap(at point: Point) -> Bool {
        guard let box = lastDisplayList.hitTest(point) else { return false }
        box.action() // 在图更新之外执行：动作里修改 @State 只会排队一个事务
        return true
    }

    /// 点击标签中包含 label 的按钮。
    @discardableResult
    public func tap(_ label: String) -> Bool {
        guard let box = lastDisplayList.findButton(containing: label) else { return false }
        box.action()
        return true
    }
}
