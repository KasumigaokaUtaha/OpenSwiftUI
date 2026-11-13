// MiniSwiftUIDemo —— 教程中每一章对应的可运行示例。
//
//   swift run MiniSwiftUIDemo          # 运行全部章节
//   swift run MiniSwiftUIDemo 3        # 只运行第 3 章

import MiniSwiftUI

func chapter(_ n: Int, _ title: String, _ body: () -> Void) {
    let args = CommandLine.arguments.dropFirst()
    guard args.isEmpty || args.contains(String(n)) else { return }
    print("\n════════ 第 \(n) 章：\(title) ════════\n")
    body()
}

/// 运行 body，并打印期间被重新计算的图节点。
func traced(_ label: String, _ body: () -> Void) {
    let log = Graph.shared.trace(body)
    let bodies = log.filter { $0.hasPrefix("body(") }
    print("· \(label)：重新运行了 \(log.count - bodies.count) 个图节点，真正调用 body \(bodies.count) 次 \(bodies)")
}

// MARK: - 第 1 章：State 与增量更新

struct CounterView: View {
    @State var count = 0

    var body: some View {
        VStack(spacing: 1) {
            Text("Count: \(count)")
            HStack {
                Button("[ - ]") { count -= 1 }
                Button("[ + ]") { count += 1 }
            }
            StaticFooter()
        }
    }
}

/// 没有任何状态、也不依赖父视图数据的子视图。
struct StaticFooter: View {
    var body: some View { Text("(footer)") }
}

chapter(1, "State 与增量更新") {
    let host = ConsoleHostingView(rootView: CounterView(), width: 24, height: 7)
    traced("首次渲染") { print(host.renderFramed()) }
    host.tap("[ + ]")
    host.tap("[ + ]")
    traced("点击两次 [ + ] 后再渲染") { print(host.renderFramed()) }
    print("注意：StaticFooter 的 body 没有被重新求值 —— 它的输入（视图值）没有变化。")
}

// MARK: - 第 2 章：结构化身份 —— if/else 会销毁状态

struct ToggleableCounter: View {
    @State var showDetail = false
    var body: some View {
        VStack {
            Button(showDetail ? "[hide]" : "[show]") { showDetail.toggle() }
            if showDetail {
                CounterView()
            } else {
                Text("detail hidden")
            }
        }
    }
}

chapter(2, "结构化身份：if/else 分支切换会销毁状态") {
    let host = ConsoleHostingView(rootView: ToggleableCounter(), width: 24, height: 9)
    host.render()
    host.tap("[show]"); host.render()
    host.tap("[ + ]"); host.tap("[ + ]"); host.tap("[ + ]")
    print(host.renderFramed())
    host.tap("[hide]"); host.render()
    host.tap("[show]")
    print(host.renderFramed())
    print("隐藏再显示后计数归零：旧分支所在的 Subgraph 已被销毁，@State 存储随之消失。")
}

// MARK: - 第 3 章：ForEach 与显式身份

struct Item: Identifiable, Equatable {
    var id: Int
    var name: String
}

struct Row: View {
    let item: Item
    @State var likes = 0
    var body: some View {
        HStack {
            Text(item.name)
            Spacer()
            Button("♥\(likes)") { likes += 1 }
        }
    }
}

struct ListView: View {
    @State var items = [Item(id: 1, name: "apple"), Item(id: 2, name: "banana"), Item(id: 3, name: "cherry")]
    var body: some View {
        VStack {
            ForEach(items) { item in Row(item: item) }
            Button("[remove first]") { items.removeFirst() }
            Button("[reverse]") { items.reverse() }
        }
    }
}

chapter(3, "ForEach：按 ID 保留每一行的状态") {
    let host = ConsoleHostingView(rootView: ListView(), width: 22, height: 6)
    host.render()
    host.tap("♥0")             // 给 apple 点赞（第一个 ♥0 按钮）
    host.tap(at: Point(x: 20, y: 1)) // 给 banana 点赞（点击坐标）
    host.render()
    host.tap(at: Point(x: 20, y: 1))
    print(host.renderFramed())
    host.tap("[reverse]")
    print(host.renderFramed())
    host.tap("[remove first]")
    print(host.renderFramed())
    print("反转后点赞数跟着各自的行走：每行的 @State 属于以 ID 标识的子图，而不是「第几行」。")
}

// MARK: - 第 4 章：Environment

struct Badge: View {
    @Environment(\.textCase) var textCase
    var body: some View {
        Text("case=\(textCase.map { "\($0)" } ?? "nil")")
    }
}

struct EnvironmentDemo: View {
    @State var upper = false
    var body: some View {
        VStack {
            Button("[toggle]") { upper.toggle() }
            Text("Hello Environment")
            Badge()
            HStack { Color.primary.frame(width: 3, height: 1); Color.primary.frame(width: 3, height: 1) }
                .foregroundFill("*")
        }
        .textCase(upper ? .uppercase : nil)
    }
}

chapter(4, "Environment：自上而下的数据流") {
    let host = ConsoleHostingView(rootView: EnvironmentDemo(), width: 22, height: 4)
    print(host.renderFramed())
    host.tap("[toggle]")
    traced("切换 textCase 后") { print(host.renderFramed()) }
}

// MARK: - 第 5 章：布局协商

struct LayoutDemo: View {
    var body: some View {
        VStack(alignment: .start) {
            HStack { Text("left"); Spacer(); Text("right") }
            HStack(spacing: 0) { Color.red; Text("fixed"); Color.blue }
            Text("a long text that wraps").frame(width: 10)
            Text("padded").padding(1).background(Color.gray)
        }
    }
}

chapter(5, "布局：提议尺寸 → 回答尺寸 → 放置") {
    let host = ConsoleHostingView(rootView: LayoutDemo(), width: 24, height: 9)
    print(host.renderFramed())
    host.setSize(width: 16, height: 9)
    print(host.renderFramed())
    print("显示列表（相当于 SWIFTUI_PRINT_TREE=1 打印的内容）：")
    print(host.lastDisplayList)
}

// MARK: - 第 6 章：Preference

struct ScoreKey: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

struct PreferenceDemo: View {
    @State var total = 0
    @State var extra = false
    var body: some View {
        VStack {
            Text("total = \(total)")
            VStack {
                Text("A").preference(key: ScoreKey.self, value: 10)
                Text("B").preference(key: ScoreKey.self, value: 5)
                if extra { Text("C").preference(key: ScoreKey.self, value: 100) }
            }
            .onPreferenceChange(ScoreKey.self) { total = $0 }
            Button("[add C]") { extra = true }
        }
    }
}

chapter(6, "Preference：自下而上的数据流") {
    let host = ConsoleHostingView(rootView: PreferenceDemo(), width: 16, height: 5)
    print(host.renderFramed())
    host.tap("[add C]")
    print(host.renderFramed())
}

// MARK: - 第 7 章：Transaction 与动画

struct AnimationDemo: View {
    @State var moved = false
    var body: some View {
        VStack {
            HStack { Text(">>").offset(x: moved ? 16 : 0); Spacer() }
            Button("[go]") { withAnimation(.linear(duration: 0.4)) { moved.toggle() } }
        }
    }
}

chapter(7, "Transaction 与动画") {
    let host = ConsoleHostingView(rootView: AnimationDemo(), width: 20, height: 2)
    print(host.renderFramed(at: 0))
    host.tap("[go]")
    var t = 1.0
    print(host.render(at: t))
    while let next = host.nextUpdateTime {
        t = next
        print(host.render(at: t).split(separator: "\n")[0], " t=\(Int((t - 1) * 1000))ms")
    }
    print("动画结束，nextUpdateTime == nil，宿主不再请求新帧。")
}

// MARK: - 第 8 章：自定义 ViewModifier

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(1).background(Color.gray)
    }
}

chapter(8, "自定义 ViewModifier") {
    let host = ConsoleHostingView(rootView: Text("card").modifier(Card()), width: 10, height: 3)
    print(host.renderFramed())
    print("图中现存节点数：\(Graph.shared.liveNodeCount)")
}
