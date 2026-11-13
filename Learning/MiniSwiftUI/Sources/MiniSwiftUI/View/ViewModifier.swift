// ViewModifier.swift
//
// `Text("hi").padding()` 的类型是 ModifiedContent<Text, _PaddingLayout>。
// ModifiedContent._makeView 把控制权交给修饰符：
//
//     Modifier._makeView(modifier: view[\.modifier], inputs: inputs) { inputs in
//         Content._makeView(view: view[\.content], inputs: inputs)
//     }
//
// 修饰符可以：在调用 body 闭包前改写 inputs（环境、几何……），
// 也可以在拿到 outputs 后改写/包装 outputs（显示列表、布局、偏好……）。
// 这就是 SwiftUI 中「修饰符」的全部魔法。

public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>

    @ViewBuilder func body(content: Content) -> Body

    static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs
}

/// 原语修饰符：自己实现 _makeView，没有 body。
public protocol _PrimitiveViewModifier: ViewModifier where Body == Never {}

extension _PrimitiveViewModifier {
    public func body(content: Content) -> Never { preconditionFailure("\(Self.self) 是原语修饰符") }
}

extension ViewModifier {
    /// 自定义修饰符：和自定义视图一样，建一个 body 规则节点，然后安装它的 body。
    /// `content` 占位符通过 inputs 找到真正的被修饰视图（真实 SwiftUI：_ViewModifier_Content + BodyInput）。
    public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        precondition(Body.self != Never.self, "\(Self.self) 是原语修饰符，必须自己实现 _makeView")
        var inputs = inputs
        inputs.modifierBodies[ObjectIdentifier(Self.self)] = body
        let bodyAttribute = Attribute(BodyRule<Self, Body>(
            container: modifier.value,
            inputs: inputs.base,
            subgraph: Subgraph.current,
            makeBody: { $0.body(content: _ViewModifier_Content()) }
        ))
        return Body._makeView(view: _GraphValue(bodyAttribute), inputs: inputs)
    }
}

public struct _ViewModifier_Content<Modifier: ViewModifier>: View, _PrimitiveView {
    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        guard let body = inputs.modifierBodies[ObjectIdentifier(Modifier.self)] else {
            preconditionFailure("找不到 \(Modifier.self) 的 content")
        }
        return body(inputs)
    }
}

public struct ModifiedContent<Content, Modifier> {
    public var content: Content
    public var modifier: Modifier
}

extension ModifiedContent: View where Content: View, Modifier: ViewModifier {
    public typealias Body = Never
    public var body: Never { preconditionFailure() }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        Modifier._makeView(modifier: view[\.modifier], inputs: inputs) { inputs in
            Content._makeView(view: view[\.content], inputs: inputs)
        }
    }

    // 简化：被修饰的视图在列表中总是占一个位置。
    // （真实 SwiftUI 中，修饰一个多元视图会把修饰符分别作用到每个元素上。）
    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs {
        .unary { inputs in Self._makeView(view: view, inputs: inputs) }
    }
}

extension View {
    public func modifier<M: ViewModifier>(_ modifier: M) -> ModifiedContent<Self, M> {
        ModifiedContent(content: self, modifier: modifier)
    }
}

// MARK: - background

public struct _BackgroundModifier<Background: View>: _PrimitiveViewModifier {
    public var background: Background

    public static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        // 背景和内容共用同一份几何输入；布局只由内容决定。
        var backgroundInputs = inputs
        backgroundInputs.stackAxis = nil
        let background = Background._makeView(view: modifier[\.background], inputs: backgroundInputs)
        let content = body(inputs)
        var outputs = _ViewOutputs()
        outputs.layoutComputer = content.layoutComputer
        outputs.preferences = combinePreferences([background, content], keys: inputs.preferenceKeys).preferences
        return outputs
    }
}

extension View {
    public func background<B: View>(_ background: B) -> some View {
        modifier(_BackgroundModifier(background: background))
    }
}
