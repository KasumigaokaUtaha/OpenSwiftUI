// DisplayList.swift
//
// 图的最终产物不是「视图对象」，而是一份描述「画什么、画在哪」的显示列表。
// 宿主（UIHostingView / NSHostingView / 我们的控制台宿主）拿到它之后，交给渲染器：
// 真实 SwiftUI 会把它增量地同步到 CALayer / UIView 树（DisplayList.ViewUpdater），
// 或用 RenderBox 直接绘制；OpenSwiftUI 在 Linux 上则有一个打印到 stdout 的渲染器。
//
// 真实结构见 OpenSwiftUICore/Render/DisplayList/DisplayList.swift：
// DisplayList { items: [Item] }，Item { frame, value: .content / .effect(Effect, DisplayList) / ... , identity }。

public struct DisplayList: CustomStringConvertible {
    public var items: [Item] = []

    public init() {}
    public init(_ item: Item) { items = [item] }

    public struct Item {
        public var frame: Rect
        public var value: Value
        /// 稳定身份：同一个视图在多次更新中产生的 Item 身份相同，渲染器据此复用平台对象。
        public var identity: Int
    }

    public indirect enum Value {
        case content(Content)
        case effect(Effect, DisplayList)
    }

    public enum Content {
        case text(String)
        case color(Character)
    }

    public enum Effect {
        case offset(x: Double, y: Double)
        case tapTarget(ActionBox)
    }

    /// 显示列表是一种偏好：叶子产生，沿树向上按顺序拼接（后面的画在上面）。
    public struct Key: PreferenceKey {
        public static var defaultValue: DisplayList { DisplayList() }
        public static func reduce(value: inout DisplayList, nextValue: () -> DisplayList) {
            value.items += nextValue().items
        }
    }

    /// 类似真实 SwiftUI 设置 SWIFTUI_PRINT_TREE=1 后打印的显示列表树。
    public var description: String {
        var lines: [String] = []
        func dump(_ list: DisplayList, _ indent: String) {
            for item in list.items {
                let head = "\(indent)(item #\(item.identity) frame: \(item.frame)"
                switch item.value {
                case let .content(.text(s)): lines.append("\(head) text: \"\(s)\")")
                case let .content(.color(c)): lines.append("\(head) color: '\(c)')")
                case let .effect(effect, child):
                    switch effect {
                    case let .offset(x, y): lines.append("\(head) effect: offset(\(fmt(x)), \(fmt(y)))")
                    case .tapTarget: lines.append("\(head) effect: tapTarget")
                    }
                    dump(child, indent + "  ")
                }
            }
        }
        dump(self, "")
        return lines.joined(separator: "\n")
    }
}

/// 按钮动作的容器。它是 class，并且在按钮的整个生命周期中保持同一个实例，
/// 这样显示列表比较时不会因为闭包「无法比较」而每次都被判定为变化。
public final class ActionBox {
    var action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

// MARK: - 控制台渲染器

public struct ConsoleRenderer {
    public var width: Int
    public var height: Int
    public var background: Character = " "

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public func render(_ list: DisplayList) -> String {
        var canvas = Array(repeating: Array(repeating: background, count: width), count: height)
        draw(list, dx: 0, dy: 0, into: &canvas)
        return canvas.map { String($0) }.joined(separator: "\n")
    }

    private func draw(_ list: DisplayList, dx: Double, dy: Double, into canvas: inout [[Character]]) {
        for item in list.items {
            let x0 = Int((item.frame.origin.x + dx).rounded())
            let y0 = Int((item.frame.origin.y + dy).rounded())
            let x1 = Int((item.frame.origin.x + dx + item.frame.size.width).rounded())
            let y1 = Int((item.frame.origin.y + dy + item.frame.size.height).rounded())
            switch item.value {
            case let .content(.color(c)):
                for y in max(0, y0)..<max(max(0, y0), min(height, y1)) {
                    for x in max(0, x0)..<max(max(0, x0), min(width, x1)) { canvas[y][x] = c }
                }
            case let .content(.text(s)):
                let w = max(1, x1 - x0)
                let chars = Array(s)
                for (i, ch) in chars.enumerated() {
                    let x = x0 + i % w, y = y0 + i / w
                    guard y < y1, y >= 0, y < height, x >= 0, x < width else { continue }
                    canvas[y][x] = ch
                }
            case let .effect(.offset(ox, oy), child):
                draw(child, dx: dx + ox, dy: dy + oy, into: &canvas)
            case let .effect(.tapTarget, child):
                draw(child, dx: dx, dy: dy, into: &canvas)
            }
        }
    }
}

extension DisplayList {
    /// 命中测试：找到包含该点的最上层可点击目标（后绘制的在上面）。
    func hitTest(_ point: Point, dx: Double = 0, dy: Double = 0) -> ActionBox? {
        for item in items.reversed() {
            switch item.value {
            case let .effect(.offset(ox, oy), child):
                if let hit = child.hitTest(point, dx: dx + ox, dy: dy + oy) { return hit }
            case let .effect(.tapTarget(box), child):
                if let hit = child.hitTest(point, dx: dx, dy: dy) { return hit }
                var frame = item.frame
                frame.origin = frame.origin + Point(x: dx, y: dy)
                if frame.contains(point) { return box }
            case .content: continue
            }
        }
        return nil
    }

    /// 找到「标签文本包含 label」的按钮。
    func findButton(containing label: String) -> ActionBox? {
        for item in items {
            switch item.value {
            case let .effect(.tapTarget(box), child):
                if child.containsText(label) { return box }
            case let .effect(_, child):
                if let box = child.findButton(containing: label) { return box }
            case .content: continue
            }
        }
        return nil
    }

    func containsText(_ label: String) -> Bool {
        items.contains { item in
            switch item.value {
            case let .content(.text(s)): return s.contains(label)
            case .content: return false
            case let .effect(_, child): return child.containsText(label)
            }
        }
    }
}
