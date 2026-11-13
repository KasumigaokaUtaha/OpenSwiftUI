// Geometry.swift —— 基础几何类型。单位是「控制台字符格」。

public struct Point: Equatable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
    public static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    public var description: String { "(\(fmt(x)), \(fmt(y)))" }
}

public struct Size: Equatable, CustomStringConvertible {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public static let zero = Size(width: 0, height: 0)

    public subscript(axis: Axis) -> Double {
        get { axis == .horizontal ? width : height }
        set { if axis == .horizontal { width = newValue } else { height = newValue } }
    }

    public var description: String { "\(fmt(width))×\(fmt(height))" }
}

public struct Rect: Equatable, CustomStringConvertible {
    public var origin: Point
    public var size: Size
    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public func contains(_ p: Point) -> Bool {
        p.x >= origin.x && p.x < origin.x + size.width && p.y >= origin.y && p.y < origin.y + size.height
    }
    public var description: String { "\(origin) \(size)" }
}

public enum Axis: Equatable {
    case horizontal, vertical
    var other: Axis { self == .horizontal ? .vertical : .horizontal }
}

/// 父视图给子视图的「建议尺寸」。nil 表示「你自己挑个理想尺寸」。
/// 真实 SwiftUI：_ProposedSize / ProposedViewSize。
public struct ProposedSize: Equatable {
    public var width: Double?
    public var height: Double?
    public init(width: Double?, height: Double?) { self.width = width; self.height = height }
    public init(_ size: Size) { width = size.width; height = size.height }
    public static let unspecified = ProposedSize(width: nil, height: nil)

    init(axis: Axis, major: Double?, minor: Double?) {
        if axis == .horizontal { self.init(width: major, height: minor) } else { self.init(width: minor, height: major) }
    }

    public subscript(axis: Axis) -> Double? { axis == .horizontal ? width : height }

    func inset(by insets: EdgeInsets) -> ProposedSize {
        ProposedSize(
            width: width.map { max(0, $0 - insets.leading - insets.trailing) },
            height: height.map { max(0, $0 - insets.top - insets.bottom) }
        )
    }
}

/// 布局的最终结果：一个视图在根坐标系中的位置与尺寸（真实：ViewGeometry）。
public struct ViewGeometry: Equatable {
    public var origin: Point
    public var size: Size
    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    public static let zero = ViewGeometry(origin: .zero, size: .zero)
}

public struct EdgeInsets: Equatable {
    public var top, leading, bottom, trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public init(_ all: Double) { self.init(top: all, leading: all, bottom: all, trailing: all) }
}

func fmt(_ d: Double) -> String {
    d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(format: d)
}

private extension String {
    init(format value: Double) {
        let scaled = (value * 100).rounded() / 100
        self = "\(scaled)"
    }
}
