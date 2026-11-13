// PrimitiveViews.swift —— Text、Color、Spacer、Button。

// MARK: - Text

public struct Text: View, _PrimitiveView {
    public var string: String
    public init(_ string: String) { self.string = string }

    static func resolve(_ text: Text, _ env: EnvironmentValues) -> String {
        switch env.textCase {
        case .uppercase?: text.string.uppercased()
        case .lowercase?: text.string.lowercased()
        case nil: text.string
        }
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeLeafView(
            view: view,
            layout: { text, env in TextLayoutEngine(string: resolve(text, env)) },
            content: { text, _, env in .text(resolve(text, env)) }
        )
    }
}

/// 文本布局：宽度不够时按字符折行。
struct TextLayoutEngine: LayoutEngine {
    let string: String
    func sizeThatFits(_ p: ProposedSize) -> Size {
        let n = Double(string.count)
        guard n > 0 else { return .zero }
        guard let width = p.width, width < n else { return Size(width: n, height: 1) }
        let w = max(1, width.rounded(.down))
        return Size(width: w, height: (n / w).rounded(.up))
    }
}

// MARK: - Color

/// 控制台里的「颜色」就是一个填充字符。颜色是灵活的：给多大就占多大。
public struct Color: View, _PrimitiveView, Equatable {
    public var fill: Character?
    public init(fill: Character) { self.fill = fill }
    init(environmentFill: ()) { fill = nil }

    public static let gray = Color(fill: "░")
    public static let blue = Color(fill: "▒")
    public static let red = Color(fill: "▓")
    public static let black = Color(fill: "█")
    /// 使用环境中的 foregroundFill（演示环境如何影响叶子视图）。
    public static let primary = Color(environmentFill: ())

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeLeafView(
            view: view,
            layout: { _, _ in ColorLayoutEngine() },
            content: { color, _, env in .color(color.fill ?? env.foregroundFill ?? "#") }
        )
    }
}

struct ColorLayoutEngine: LayoutEngine {
    // 真实 SwiftUI 中没有提议时 Color 的理想尺寸是 10pt；控制台里取 1 格。
    func sizeThatFits(_ p: ProposedSize) -> Size { Size(width: p.width ?? 1, height: p.height ?? 1) }
}

// MARK: - Spacer

public struct Spacer: View, _PrimitiveView {
    public var minLength: Double
    public init(minLength: Double = 0) { self.minLength = minLength }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let axis = inputs.stackAxis // 沿父栈的主轴伸展（真实：_ViewInputs.stackOrientation）
        return inputs.makeLeafView(
            view: view,
            layout: { spacer, _ in SpacerLayoutEngine(axis: axis, minLength: spacer.minLength) },
            content: { _, _, _ in nil }
        )
    }
}

struct SpacerLayoutEngine: LayoutEngine {
    let axis: Axis?
    let minLength: Double
    func sizeThatFits(_ p: ProposedSize) -> Size {
        switch axis {
        case .horizontal?: Size(width: max(minLength, p.width ?? minLength), height: 0)
        case .vertical?: Size(width: 0, height: max(minLength, p.height ?? minLength))
        case nil: Size(width: max(minLength, p.width ?? minLength), height: max(minLength, p.height ?? minLength))
        }
    }
}

// MARK: - Button

public struct Button<Label: View>: View, _PrimitiveView {
    public var action: () -> Void
    public var label: Label

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        var outputs = Label._makeView(view: view[\.label], inputs: inputs)
        if inputs.preferenceKeys.contains(DisplayList.Key.self) {
            let action = Attribute(ButtonAction(button: view.value))
            let labelList = outputs[DisplayList.Key.self] ?? Attribute(value: DisplayList())
            outputs[DisplayList.Key.self] = Attribute(ButtonDisplayList(
                action: action, label: labelList, position: inputs.position, size: inputs.size
            ))
        }
        return outputs
    }
}

extension Button where Label == Text {
    public init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

/// 始终返回同一个 ActionBox，只是把最新的闭包放进去。
struct ButtonAction<Label: View>: StatefulRule, CustomStringConvertible {
    typealias Value = ActionBox
    @Attribute var button: Button<Label>
    mutating func updateValue() {
        let action = button.action
        if hasValue { value.action = action } else { value = ActionBox(action) }
    }
    var description: String { "ButtonAction" }
}

struct ButtonDisplayList: Rule, CustomStringConvertible {
    @Attribute var action: ActionBox
    @Attribute var label: DisplayList
    @Attribute var position: Point
    @Attribute var size: Size
    var value: DisplayList {
        DisplayList(DisplayList.Item(
            frame: Rect(origin: position, size: size),
            value: .effect(.tapTarget(action), label),
            identity: Graph.shared.currentAttribute?.rawValue ?? 0
        ))
    }
    var description: String { "DisplayList(Button)" }
}

extension View {
    /// 设置子树中 `Color.primary` 的填充字符。
    public func foregroundFill(_ fill: Character) -> some View {
        environment(\.foregroundFill, fill)
    }
}
