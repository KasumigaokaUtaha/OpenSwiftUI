// Animation.swift
//
// SwiftUI 的动画并不是「对视图做动画」，而是「对图中某个可插值的值做动画」：
//
//   * 可动画的东西遵守 Animatable，暴露一个 animatableData（向量空间里的一个点）。
//   * 可动画的修饰符在 _makeView 中用 AnimatableAttribute 包住自己的值。
//   * 当源值变化、而当前 Transaction 带有 animation 时，AnimatableAttribute 不直接
//     输出新值，而是记下 from/to，然后在之后每一帧根据 time 节点插值输出中间值，
//     并请求宿主在下一帧再更新一次（真实：ViewGraph.nextUpdate / AnimatorState）。
//
// 所以「withAnimation」本质上只是让状态变化携带一个 Transaction。

public protocol VectorArithmetic: AdditiveArithmetic {
    mutating func scale(by rhs: Double)
}

extension Double: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= rhs }
}

public struct AnimatablePair<First: VectorArithmetic, Second: VectorArithmetic>: VectorArithmetic {
    public var first: First
    public var second: Second
    public init(_ first: First, _ second: Second) { self.first = first; self.second = second }
    public static var zero: Self { Self(.zero, .zero) }
    public static func + (l: Self, r: Self) -> Self { Self(l.first + r.first, l.second + r.second) }
    public static func - (l: Self, r: Self) -> Self { Self(l.first - r.first, l.second - r.second) }
    public mutating func scale(by rhs: Double) { first.scale(by: rhs); second.scale(by: rhs) }
}

public protocol Animatable {
    associatedtype AnimatableData: VectorArithmetic
    var animatableData: AnimatableData { get set }
}

public struct Animation: Equatable, CustomStringConvertible {
    public enum Curve: Equatable { case linear, easeInOut }
    public var duration: Double
    public var curve: Curve

    public static func linear(duration: Double) -> Animation { Animation(duration: duration, curve: .linear) }
    public static func easeInOut(duration: Double) -> Animation { Animation(duration: duration, curve: .easeInOut) }
    public static let `default` = Animation.easeInOut(duration: 0.35)

    /// 已经过 elapsed 秒时的进度（0...1）。
    func fraction(elapsed: Double) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(1, max(0, elapsed / duration))
        switch curve {
        case .linear: return t
        case .easeInOut: return t * t * (3 - 2 * t) // smoothstep
        }
    }

    public var description: String { "\(curve)(\(fmt(duration))s)" }
}

// MARK: - AnimatableAttribute

/// 真实 SwiftUI：OpenSwiftUICore/Animation/Animatable/AnimatableAttribute.swift。
struct AnimatableAttribute<Value: Animatable>: StatefulRule, CustomStringConvertible {
    @Attribute var source: Value
    @Attribute var time: Double
    @Attribute var transaction: Transaction

    struct Animator {
        var from: Value.AnimatableData
        var to: Value.AnimatableData
        var animation: Animation
        var startTime: Double?
    }
    var animator: Animator?

    init(source: Attribute<Value>, time: Attribute<Double>, transaction: Attribute<Transaction>) {
        _source = source
        _time = time
        _transaction = transaction
    }

    mutating func updateValue() {
        let (source, sourceChanged) = $source.changedValue()
        guard hasValue else { value = source; return }

        if sourceChanged {
            let transaction = transaction
            if let animation = transaction.animation, !transaction.disablesAnimations {
                // 从「当前屏幕上显示的值」出发（可能正处在上一段动画中途）。
                animator = Animator(from: value.animatableData, to: source.animatableData, animation: animation, startTime: nil)
            } else {
                animator = nil
                value = source
                return
            }
        }

        guard var animator else { return }
        let now = time
        let start = animator.startTime ?? now
        animator.startTime = start
        let progress = animator.animation.fraction(elapsed: now - start)
        if progress >= 1 {
            self.animator = nil
            value = source
        } else {
            var delta = animator.to - animator.from
            delta.scale(by: progress)
            var current = source
            current.animatableData = animator.from + delta
            value = current
            self.animator = animator
            ViewGraph.current?.requestUpdate(at: now + ViewGraph.frameInterval)
        }
    }

    var description: String { "AnimatableAttribute<\(Value.self)>" }
}

// MARK: - offset 修饰符（一个可动画的几何效果）

public struct _OffsetEffect: _PrimitiveViewModifier, Animatable {
    public var x: Double
    public var y: Double

    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(x, y) }
        set { x = newValue.first; y = newValue.second }
    }

    public static func _makeView(
        modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        var outputs = body(inputs)
        // 几何效果不影响布局，只影响显示列表（真实 SwiftUI 还会修改子视图的 transform 输入）。
        if let content = outputs[DisplayList.Key.self] {
            let animated = Attribute(AnimatableAttribute(
                source: modifier.value, time: inputs.base.time, transaction: inputs.base.transaction
            ))
            outputs[DisplayList.Key.self] = Attribute(OffsetDisplayList(effect: animated, content: content))
        }
        return outputs
    }
}

struct OffsetDisplayList: Rule, CustomStringConvertible {
    @Attribute var effect: _OffsetEffect
    @Attribute var content: DisplayList
    var value: DisplayList {
        let frame = content.items.first?.frame ?? Rect(origin: .zero, size: .zero)
        return DisplayList(DisplayList.Item(
            frame: frame,
            value: .effect(.offset(x: effect.x, y: effect.y), content),
            identity: Graph.shared.currentAttribute?.rawValue ?? 0
        ))
    }
    var description: String { "DisplayList(offset)" }
}

extension View {
    public func offset(x: Double = 0, y: Double = 0) -> some View {
        modifier(_OffsetEffect(x: x, y: y))
    }
}
