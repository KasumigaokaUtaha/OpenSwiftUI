# SwiftUI 原理学习资料

这个目录是一套中文学习资料，目标是弄懂 SwiftUI 的核心思想：

| 文档 | 内容 |
|---|---|
| [01-逆向流程还原.md](01-逆向流程还原.md) | 从 OpenSwiftUI 的 1337 个提交还原逆向 SwiftUI 的过程：用到的工具、私有框架链接、逐文件审计、用真 SwiftUI 做对照测试；以及从代码反推 DanceUI 的来历 |
| [02-架构与组件剖析.md](02-架构与组件剖析.md) | OpenSwiftUI / DanceUI / OpenAttributeGraph / Compute 的整体架构，以及 AttributeGraph、`_makeView`、State、Environment、Preference、布局、ViewList、动画、DisplayList 等关键组件的源码解读 |
| [03-MiniSwiftUI教程.md](03-MiniSwiftUI教程.md) | 配合 `MiniSwiftUI/` 原型的 9 课教程，每课都对应真实实现 |
| [MiniSwiftUI/](MiniSwiftUI) | 约 3000 行、无 Foundation 依赖的 SwiftUI 简化原型（SwiftPM，Linux/macOS），带 8 章控制台示例和 10 个测试 |

```bash
cd Learning/MiniSwiftUI && swift run MiniSwiftUIDemo
```

建议的阅读顺序：先跑一遍 Demo，读 03 的第 1～3 课，然后对照 02 去看 OpenSwiftUI 的真实源码，最后读 01 了解这些知识是怎么被「挖」出来的。
