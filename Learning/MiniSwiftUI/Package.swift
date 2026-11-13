// swift-tools-version:5.9
//
// MiniSwiftUI —— 一个用于学习 SwiftUI 核心思想的极简原型。
// 在 Linux / macOS 上都可以用 `swift run MiniSwiftUIDemo` 运行，用 `swift test` 跑测试。

import PackageDescription

let package = Package(
    name: "MiniSwiftUI",
    products: [
        .library(name: "MiniSwiftUI", targets: ["MiniSwiftUI"]),
        .executable(name: "MiniSwiftUIDemo", targets: ["MiniSwiftUIDemo"]),
    ],
    targets: [
        .target(
            name: "MiniSwiftUI",
            // 不依赖 Foundation；Linux 上 Double.rounded() 需要链接 libm。
            linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]
        ),
        .executableTarget(name: "MiniSwiftUIDemo", dependencies: ["MiniSwiftUI"]),
        .testTarget(name: "MiniSwiftUITests", dependencies: ["MiniSwiftUI"]),
    ]
)
