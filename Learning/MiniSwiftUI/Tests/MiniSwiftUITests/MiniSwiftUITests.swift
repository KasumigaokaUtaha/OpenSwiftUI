import XCTest
@testable import MiniSwiftUI

// MARK: - 图引擎

struct Sum: Rule {
    @Attribute var a: Int
    @Attribute var b: Int
    var value: Int { a + b }
}

struct IsEven: Rule {
    @Attribute var x: Int
    var value: Bool { x % 2 == 0 }
}

struct Describe: Rule {
    @Attribute var even: Bool
    var value: String { even ? "even" : "odd" }
}

final class GraphTests: XCTestCase {
    func testPushDirtyPullUpdate() {
        let a = Attribute(value: 1)
        let b = Attribute(value: 2)
        let sum = Attribute(Sum(a: a, b: b))
        XCTAssertEqual(sum.value, 3)

        // 写入相同的值：不算变化，不会重算。
        XCTAssertFalse(a.setValue(1))
        XCTAssertEqual(Graph.shared.trace { _ = sum.value }, [])

        a.value = 10
        XCTAssertEqual(Graph.shared.trace { _ = sum.value }, ["Sum"])
        XCTAssertEqual(sum.value, 12)
    }

    func testEqualValueCutsOffPropagation() {
        let x = Attribute(value: 2)
        let even = Attribute(IsEven(x: x))
        let text = Attribute(Describe(even: even))
        XCTAssertEqual(text.value, "even")

        x.value = 4 // IsEven 会重算，但结果仍是 true —— Describe 不必重算
        XCTAssertEqual(Graph.shared.trace { _ = text.value }, ["IsEven"])

        x.value = 5
        XCTAssertEqual(Graph.shared.trace { _ = text.value }, ["IsEven", "Describe"])
        XCTAssertEqual(text.value, "odd")
    }

    func testCompareValuesWithoutEquatable() {
        struct Plain { var a: Int; var s: String; var obj: AnyObject }
        let o = NSObjectLike()
        XCTAssertTrue(compareValues(Plain(a: 1, s: "x", obj: o), Plain(a: 1, s: "x", obj: o)))
        XCTAssertFalse(compareValues(Plain(a: 1, s: "x", obj: o), Plain(a: 1, s: "x", obj: NSObjectLike())))
        let f: () -> Void = {}
        XCTAssertFalse(compareValues(f, f), "闭包无法比较，保守地视为变化")
    }
}

final class NSObjectLike {}

// MARK: - 视图

struct Footer: View {
    var body: some View { Text("footer") }
}

struct Counter: View {
    @State var count = 0
    var body: some View {
        VStack {
            Text("count \(count)")
            Button("inc") { count += 1 }
            Footer()
        }
    }
}

final class ViewTests: XCTestCase {
    func testStateChangeReevaluatesOnlyAffectedBody() {
        let host = ConsoleHostingView(rootView: Counter(), width: 10, height: 3)
        XCTAssertTrue(host.render().contains("count 0"))
        XCTAssertTrue(host.tap("inc"))
        var output = ""
        let log = Graph.shared.trace { output = host.render() }
        XCTAssertTrue(output.contains("count 1"))
        XCTAssertTrue(log.contains("body(Counter)"))
        XCTAssertFalse(log.contains("body(Footer)"))
    }

    struct Toggler: View {
        @State var on = true
        var body: some View {
            VStack {
                Button("flip") { on.toggle() }
                if on { Counter() } else { Text("off") }
            }
        }
    }

    func testBranchSwitchDiscardsState() {
        let host = ConsoleHostingView(rootView: Toggler(), width: 10, height: 4)
        host.render()
        host.tap("inc"); host.tap("inc")
        XCTAssertTrue(host.render().contains("count 2"))
        host.tap("flip")
        XCTAssertTrue(host.render().contains("off"))
        host.tap("flip")
        XCTAssertTrue(host.render().contains("count 0"))
    }

    struct Row: View {
        let name: String
        @State var n = 0
        var body: some View { Button("\(name)=\(n)") { n += 1 } }
    }

    struct Rows: View {
        @State var names = ["a", "b", "c"]
        var body: some View {
            VStack {
                ForEach(names, id: \.self) { Row(name: $0) }
                Button("reverse") { names.reverse() }
                Button("drop") { names.removeFirst() }
            }
        }
    }

    func testForEachKeepsStateByIdentity() {
        let host = ConsoleHostingView(rootView: Rows(), width: 10, height: 5)
        host.render()
        host.tap("b=0")
        XCTAssertEqual(host.render().split(separator: "\n").map { $0.trimmingCharacters() }.prefix(3), ["a=0", "b=1", "c=0"])
        host.tap("reverse")
        XCTAssertEqual(host.render().split(separator: "\n").map { $0.trimmingCharacters() }.prefix(3), ["c=0", "b=1", "a=0"])
        host.tap("drop")
        let lines = host.render().split(separator: "\n").map { $0.trimmingCharacters() }
        XCTAssertFalse(lines.contains("c=0"))
        XCTAssertTrue(lines.contains("b=1"))
    }

    struct Reader: View {
        @Environment(\.textCase) var textCase
        var body: some View { Text(textCase == nil ? "plain" : "cased") }
    }

    func testEnvironmentOnlyInvalidatesReaders() {
        let graph = ViewGraph(rootView: Reader(), size: Size(width: 10, height: 1))
        graph.update(at: 0)
        var env = EnvironmentValues()
        env.foregroundFill = "x" // Reader 不关心这个 key
        graph.setEnvironment(env)
        XCTAssertFalse(Graph.shared.trace { graph.update(at: 0) }.contains("body(Reader)"))
        env.textCase = .uppercase
        graph.setEnvironment(env)
        XCTAssertTrue(Graph.shared.trace { graph.update(at: 0) }.contains("body(Reader)"))
    }

    func testStackLayoutNegotiation() {
        let view = HStack(spacing: 0) { Text("abc"); Color.red; Text("de") }
        let host = ConsoleHostingView(rootView: view, width: 10, height: 1)
        XCTAssertEqual(host.render(), "abc▓▓▓▓▓de")
    }

    struct Total: PreferenceKey {
        static let defaultValue = 0
        static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
    }

    func testPreferencesFlowUp() {
        var received: [Int] = []
        let view = VStack {
            Text("x").preference(key: Total.self, value: 2)
            Text("y").preference(key: Total.self, value: 3)
        }.onPreferenceChange(Total.self) { received.append($0) }
        let host = ConsoleHostingView(rootView: view, width: 4, height: 2)
        host.render()
        XCTAssertEqual(received, [5])
    }

    struct Mover: View {
        @State var right = false
        var body: some View {
            VStack {
                HStack { Text("o").offset(x: right ? 8 : 0); Spacer() }
                Button("go") { withAnimation(.linear(duration: 1)) { right = true } }
            }
        }
    }

    func testAnimationInterpolatesOverTime() {
        let host = ConsoleHostingView(rootView: Mover(), width: 10, height: 2)
        host.render(at: 0)
        host.tap("go")
        host.render(at: 10)
        XCTAssertNotNil(host.nextUpdateTime)
        let mid = host.render(at: 10.5).split(separator: "\n")[0]
        XCTAssertEqual(mid.firstIndex(of: "o").map { mid.distance(from: mid.startIndex, to: $0) }, 4)
        host.render(at: 11)
        XCTAssertNil(host.nextUpdateTime)
        let end = host.render(at: 11).split(separator: "\n")[0]
        XCTAssertEqual(end.firstIndex(of: "o").map { end.distance(from: end.startIndex, to: $0) }, 8)
    }
}

extension Substring {
    func trimmingCharacters() -> String {
        String(self.drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
    }
}
