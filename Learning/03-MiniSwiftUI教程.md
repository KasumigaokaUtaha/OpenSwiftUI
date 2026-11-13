# 03 · 用 3000 行 Swift 重新发明 SwiftUI：MiniSwiftUI 教程

> 目标：读完并跑通这个原型，你应该能回答——
> 「body 什么时候被调用？」「@State 存在哪？」「为什么 if/else 会丢状态而 ForEach 不会？」
> 「环境和偏好是怎么流动的？」「布局怎么协商？」「withAnimation 到底做了什么？」
>
> 原型代码：[`MiniSwiftUI/`](MiniSwiftUI)（不依赖 Foundation，Linux / macOS 均可构建）。
> 每一课都给出对应的真实实现位置（OpenSwiftUI 路径相对 `Sources/OpenSwiftUICore/`），细节见 [02-架构与组件剖析.md](02-架构与组件剖析.md)。

---

## 0. 运行

```bash
cd Learning/MiniSwiftUI
swift run MiniSwiftUIDemo        # 运行全部 8 章示例
swift run MiniSwiftUIDemo 3      # 只运行第 3 章
swift test                       # 10 个单元测试

# 没有本地 Swift 工具链时（例如在 Linux 服务器上），可以用官方镜像：
docker run --rm -v "$PWD":/pkg -w /pkg swift:6.0-noble swift run MiniSwiftUIDemo
```

需要 Swift 5.9+（用到了参数包 `each`）。我在 `swift:6.0-noble` 镜像里验证过构建、示例和全部测试。

### 文件地图

| MiniSwiftUI | 作用 | 真实对应 |
|---|---|---|
| `Graph/Graph.swift` | 节点、推脏、拉取、子图 | AttributeGraph（`Compute/…/Graph.cpp`、`UpdateStack.cpp`） |
| `Graph/Attribute.swift` | `Attribute`、`Rule`、`StatefulRule`、`mutateBody` | `OpenAttributeGraph/Attribute/*` |
| `Graph/CompareValues.swift` | 不依赖 Equatable 的值比较 | `AGCompareValues` |
| `View/View.swift` | `View`、`_makeView`、`BodyRule`、Inputs/Outputs | `View/View.swift`、`View/CustomView.swift`、`Data/DynamicProperty/DynamicProperty.swift` |
| `View/ViewBuilder.swift` | `TupleView`、`_ConditionalContent`、`Optional`、`AnyView` | 同名类型 |
| `View/DynamicView.swift` | 动态子图容器 | `View/ConditionalContent.swift`、`View/DynamicView/DynamicView.swift` |
| `View/ViewList.swift` | 静态/动态视图列表、`ForEach` | `View/Input/ViewList.swift`、`View/DynamicViewContent/ForEach.swift` |
| `View/ViewModifier.swift` | `ModifiedContent`、自定义修饰符、`background` | 同名类型 |
| `View/Preference.swift` | `PreferenceKey`、合并、`onPreferenceChange` | `Data/Preference/*` |
| `View/PrimitiveViews.swift` | `Text`、`Color`、`Spacer`、`Button` | 同名类型 |
| `Data/DynamicProperty.swift` | 属性扫描与盒子 | `DynamicPropertyCache`、`_DynamicPropertyBuffer` |
| `Data/State.swift` | `State`、`StoredLocation`、`Binding` | `Data/State/*`、`Data/Binding/*` |
| `Data/Environment.swift`、`PropertyList.swift` | 环境 | `Data/Environment/*`、`Data/Util/PropertyList.swift` |
| `Data/Transaction.swift`、`Animation/Animation.swift` | 事务与动画 | `Animation/Transaction/*`、`Animation/Animatable/AnimatableAttribute.swift` |
| `Layout/*` | 布局协商 | `Layout/LayoutComputer/*`、`Layout/LayoutView.swift`、`Layout/Stack/*` |
| `Render/DisplayList.swift` | 显示列表与控制台渲染器 | `Render/DisplayList/*`（含 `DisplayListStdoutRenderer.swift`） |
| `Host/ViewGraph.swift`、`ConsoleHostingView.swift` | 宿主 | `View/Graph/ViewGraph.swift`、`Graph/GraphHost.swift`、`UIHostingView` |

---

## 第 1 课 · 依赖图：SwiftUI 的发动机

**核心思想**：把整个 UI 看成一张「电子表格」。每个格子（节点）要么是你填进去的值，要么是公式（规则）。改了一个格子，只有引用它的公式需要重算；如果某个公式重算后结果没变，引用它的公式也不用算。

### 1.1 推脏、拉取、截断

`Graph/Graph.swift` 的三个函数就是全部算法：

```swift
// 推：外部写入一个输入节点
func setValue(_ value: Any, of attribute: AnyAttribute) -> Bool {
    if let old = n.value, compareValues(old, value) { return false } // 没变 → 什么都不做
    n.value = value
    n.version &+= 1                                                  // 版本号 = 「变过几次」
    propagateDirty(from: n)                                          // 沿输出边把下游标脏
    return true
}

// 拉：有人读一个节点时
func updateIfNeeded(_ n: Node) {
    guard n.isDirty || n.value == nil || n.forceRun else { return }
    var needsRun = n.value == nil || n.forceRun
    if !needsRun {
        for edge in n.inputs {                     // 先把输入更新到最新
            updateIfNeeded(nodes[edge.node])
            if nodes[edge.node].version != edge.seen { needsRun = true } // 输入真的变了吗？
        }
    }
    n.isDirty = false
    if needsRun { run(n) }                         // 只有输入变了才运行规则
}

// 截断：规则输出与旧值相等时，版本号不变 → 下游会发现「输入没变」
func setOutputValue(_ value: Any) {
    if let old = n.value, compareValues(old, value) { return }
    n.value = value
    n.version &+= 1
}
```

依赖边不需要声明：规则运行时每读一次 `@Attribute var x`，`value(of:)` 就调用 `recordDependency(on:)` 连一条边。

### 1.2 动手

`Tests/MiniSwiftUITests/MiniSwiftUITests.swift` 的 `testEqualValueCutsOffPropagation`：

```swift
let x = Attribute(value: 2)
let even = Attribute(IsEven(x: x))      // x % 2 == 0
let text = Attribute(Describe(even: even)) // even ? "even" : "odd"

x.value = 4   // IsEven 重算，结果仍是 true —— Describe 不必重算
XCTAssertEqual(Graph.shared.trace { _ = text.value }, ["IsEven"])
x.value = 5
XCTAssertEqual(Graph.shared.trace { _ = text.value }, ["IsEven", "Describe"])
```

### 1.3 规则可以有状态；构建可以「先父后子」

* `StatefulRule` 是一个可变 struct，图把它存在节点里，`updateValue()` 可以读写自己的字段（真实 SwiftUI 的 `DynamicBody` 用它保存属性盒子，`AnimatableAttribute` 用它保存动画状态）。
* `attribute.mutateBody(as:invalidating:)` 允许在节点建好之后修改它的规则——SwiftUI 常用这一招：先建父布局节点，建完孩子后把孩子的布局节点「塞回」父节点（见第 6 课）。

### 1.4 Subgraph

`Subgraph` 把节点分组，`invalidate()` 一次性销毁组内所有节点。**状态的生命周期 = 它所在子图的生命周期**——这是第 4 课「身份」的物理基础。

> 真实差异：AG 用页式内存、32 位 ID、偏移投影（`attr[keyPath:]` 不建新节点）、主线程/异步线程标记、可取消的更新（deadline）。思想完全一致。

---

## 第 2 课 · View 只是描述，`_makeView` 才是重点

```swift
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs
    static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewListOutputs
}
```

* `_makeView` 是 **static** 的，参数 `view` 不是视图值而是「装着视图值的图节点」。
* 它在视图**第一次出现**时被调用一次，往图里建节点，然后就退场了。之后的所有更新都是图自己完成的。

自定义视图的默认实现（`View/View.swift`）：

```swift
public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
    let body = makeBody(view: view, inputs: inputs)   // 新建一个 BodyRule 节点：输入 = 视图值，输出 = view.body
    return Body._makeView(view: body, inputs: inputs) // 递归安装 body
}
```

而 `@ViewBuilder` 把 body 里的结构编码进**类型**：

```swift
VStack { Text("a"); if flag { Text("b") } else { Color.red } }
// content 的类型：TupleView<Text, _ConditionalContent<Text, Color>>
```

类型是静态的 → `_makeView` 可以是静态方法 → 图的形状在构建期就确定了 → 运行期只有值在变。这是 SwiftUI 不需要「虚拟 DOM diff」的原因：**diff 的对象是图节点的值，而不是树的结构**。

`BodyRule.updateValue()` 决定 body 是否被调用：

```swift
let (container, containerChanged) = $container.changedValue()   // 视图值变了吗？
var changed = containerChanged
if buffer!.update(container: container) { changed = true }      // 动态属性（@State 等）变了吗？
if changed || !hasValue { value = makeBody(container) }         // 只有变了才调用 body
```

视图值是否「变了」靠第 1 课的 `compareValues` 判断：父视图 body 重算时生成了一个新的 `StaticFooter()`，但它和上次的值逐字段相等，于是 `StaticFooter` 的 body 规则根本不会运行。

---

## 第 3 课 · 一次 `count += 1` 的旅程

运行 `swift run MiniSwiftUIDemo 1`：

```
· 首次渲染：重新运行了 49 个图节点，真正调用 body 2 次 ["body(CounterView)", "body(StaticFooter)"]
· 点击两次 [ + ] 后再渲染：重新运行了 20 个图节点，真正调用 body 1 次 ["body(CounterView)"]
```

完整链路（`Data/State.swift` + `Host/ViewGraph.swift`）：

```
① 安装    BodyRule 第一次运行时用 Mirror 扫描 CounterView，发现 @State count
          → State._makeProperty 创建 StatePropertyBox，内含一个 Void「信号」节点

② 首次求值 StatePropertyBox.update：创建 StoredLocation(initialValue: 0)，注入视图的 State；
          读 signal（于是 BodyRule 依赖 signal）

③ 点击    ConsoleHostingView.tap → Button 的 ActionBox.action() → count += 1
          → StoredLocation.set：currentValue = 1；捕获 Transaction.current；
            host.asyncTransaction(transaction) { updateValue = currentValue; signal.invalidateValue() }
          此时图完全没动，只是排了一个队

④ 刷新    host.render() → ViewGraph.update(at:) → flushTransactions：
          设置 transaction 输入 → 执行修改：signal 版本 +1 → 推脏到 BodyRule<CounterView> 及其下游

⑤ 拉取    读取根显示列表 → 一路拉到 BodyRule<CounterView>：
          StatePropertyBox 发现 signal 变了，且上次 body 读过 count（wasRead）→ 报告变化 → 调用 body
          → 新的 Text("Count: 1") 与旧值不同 → Text 的布局、显示列表节点重算
          → 新的 StaticFooter() 与旧值相同 → 传播在此截断
```

三个值得注意的设计（都与真实 SwiftUI 一致）：

1. **写状态不会立即更新 UI**，只是排队一个事务；多次写入会合并到同一次更新里。
2. **`currentValue` 与 `updateValue` 分离**：动作闭包里写完立刻读到新值；body 在一次更新内看到的值是稳定的。
3. **`wasRead`**：body 没读过的状态，变化时不会让 body 重算。在图更新期间写状态会被拒绝并打印 `Modifying state during view update`。

> 为什么要「盒子」？真实 SwiftUI 用运行时元数据拿到 `@State` 字段的**字节偏移**，在 body 求值前直接把 `_location` 写进视图结构体的那块内存。我们没法安全地改写结构体，所以在 `State` 里放了一个 class `_link`：Mirror 拿到的副本与视图共享这个引用，写它就等于「注入」。

---

## 第 4 课 · 身份：为什么 if/else 会丢状态，ForEach 不会

### 4.1 结构化身份（`swift run MiniSwiftUIDemo 2`）

`_ConditionalContent` 的 `_makeView` 交给 `makeDynamicView`（`View/DynamicView.swift`）：

```swift
mutating func updateValue() {                  // DynamicViewContainer
    let id = childID(view)                     // "true" / "false"
    if hasValue, value.id == id { return }     // 分支没变：什么都不做
    if hasValue { value.subgraph.invalidate() }// 分支变了：销毁旧子图（@State 一起消失）
    let subgraph = Subgraph(...)               // 新建子图，在里面安装新分支
    let outputs = subgraph.apply { makeChild(id, $view, inputs) }
    value = DynamicViewInfo(id: id, outputs: outputs, subgraph: subgraph)
}
```

父视图拿到的输出是「读取容器当前值 → 再读子输出」的映射节点，这模拟了真实 SwiftUI 的 **IndirectAttribute**。演示输出：隐藏再显示后 `Count` 归零。

`AnyView` 用同一机制，只是身份换成「底层类型」——这就是「滥用 AnyView 会导致状态丢失和性能问题」的根源。

### 4.2 显式身份（`swift run MiniSwiftUIDemo 3`）

```
+----------------------+      reverse 之后         remove first 之后
|apple               ♥1|  |cherry              ♥0|  |banana              ♥2|
|banana              ♥2|  |banana              ♥2|  |apple               ♥1|
|cherry              ♥0|  |apple               ♥1|  |    [remove first]    |
```

`ForEach._makeViewList` 返回一个**动态列表**：值为 `[_DynamicListItem]` 的节点，元素按 ID 比较。栈容器中的 `DynamicContainer`（`Layout/Stack.swift`）按 ID 维护子图：

```swift
for (id, entry) in live where !newIDs.contains(id) { entry.subgraph.invalidate() } // 消失的 ID
for item in items where live[item.id] == nil { /* 新建子图并安装 */ }               // 新 ID
value = DynamicContainerInfo(ids: ..., outputs: items.map { live[$0.id]!.outputs }) // 按新顺序输出
```

每行的 `@State likes` 属于以 ID 标识的子图，所以重排时状态跟着行走；被删除的行，状态被销毁。

> 真实差异：真实 `ForEachState` 还处理视图复用/驱逐、插入删除动画（transition）、`_ViewList_ID` 的显式+隐式组合身份、懒加载（`List`、`LazyVStack`）。另外真实 SwiftUI 中 `if` 出现在 VStack 里时也会产生动态列表，而我们简化成了「占一个位置的单个视图」。

---

## 第 5 课 · Environment：自上而下

* `EnvironmentValues` = 一个 `PropertyList`：不可变链表，写入在表头前插，比较只比较表头指针（`Data/PropertyList.swift`）。
* `.environment(\.k, v)` → `_EnvironmentKeyWritingModifier._makeView` 把 `inputs.base.environment` 替换为一个 `ChildEnvironment` 规则节点，然后继续安装子视图。**修饰符改写 inputs = 影响整棵子树**。
* `@Environment(\.textCase)` 是 DynamicProperty，盒子 `EnvironmentBox` 在环境变化时重新取值，**取出的值与旧值相等就不报告变化**。

`swift run MiniSwiftUIDemo 4`：切换 `textCase` 后只有 `EnvironmentDemo`（状态变了）和 `Badge`（读了 textCase）的 body 被调用；单元测试 `testEnvironmentOnlyInvalidatesReaders` 验证了：修改一个视图不关心的环境值（`foregroundFill`）时，它的 body 不会被调用；修改它读取的 `textCase` 时才会。

---

## 第 6 课 · 布局：一场三步协商

```
父：「我给你 W×H，你要多大？」        → child.sizeThatFits(ProposedSize)
子：「我要 w×h。」                     → Size
父：「好，你放在 (x, y)，尺寸 w×h。」  → childGeometries / placement
```

在图中（`Layout/Stack.swift` 的 `makeStaticLayoutView`，对应真实的 `Layout.makeStaticView`）：

```
                 ┌─────────────── 孩子 i 的 layoutComputer ◄──────────────┐
                 ▼                                                         │
 StaticLayoutComputer ──► LayoutChildGeometries ──► ChildGeometry[i] ──► 孩子 i 的 position / size
        ▲                        ▲
     layout 值             父 position / size
```

构建顺序：先建父的 `StaticLayoutComputer`（孩子列表为空）和 `LayoutChildGeometries`，再逐个安装孩子并把投影出来的 `position/size` 交给它，最后用 `mutateBody` 把孩子们的 `layoutComputer` 回填给父节点。值的流向是单向的，所以没有循环依赖。

栈的分配算法（`StackLayoutEngine.childSizes`）：先用 0 和 ∞ 两个提议测出每个孩子的弹性，从最不灵活的孩子开始，把「剩余空间 / 剩余孩子数」提议给它。所以 `Text` 拿到刚好够用的宽度，`Spacer`/`Color` 瓜分剩余空间：

```
HStack { Text("left"); Spacer(); Text("right") }       → |left               right|
HStack(spacing: 0) { Color.red; Text("fixed"); Color.blue } → |▓▓▓▓▓▓▓▓▓fixed▒▒▒▒▒▒▒▒▒▒|
Text("a long text that wraps").frame(width: 10)         → 折成 3 行
```

`swift run MiniSwiftUIDemo 5` 还会把宿主宽度从 24 改成 16，演示「改一个根输入 → 整个布局链增量重算」，并打印显示列表树（相当于真实 SwiftUI 的 `SWIFTUI_PRINT_TREE=1`）。

`padding`、`frame` 是一元布局（`UnaryLayout`）：只有一个孩子，实现 `sizeThatFits(in:child:)` 和 `placement(of:in:)` 即可。`Spacer` 需要知道自己沿哪个方向伸展，所以父栈会在 inputs 里写入 `stackAxis`（真实：`_ViewInputs.stackOrientation`）。

---

## 第 7 课 · Preference 与 DisplayList：自下而上

偏好与环境方向相反（`View/Preference.swift`）：

1. 祖先在 `inputs.preferenceKeys` 中声明想要哪些 key——**没人要的偏好不会被计算**；
2. 写入方在 `outputs` 中放一个节点；
3. 容器用 `PreferenceCombiner` 按 `reduce` 合并孩子们的节点；
4. `onPreferenceChange` 的观察节点在值变化时把回调放进「更新结束后执行」队列（在更新中改状态是不允许的），回调里改状态会触发下一轮更新——`ViewGraph.update` 最多循环 8 次，和真实 `updateOutputs` 的 `counter != 8` 一样。

`swift run MiniSwiftUIDemo 6`：`total` 从 15 变为 115。

**最重要的一点：显示列表本身就是一种偏好。** 宿主在根 inputs 里要了 `DisplayList.Key`；叶子视图（`LeafDisplayList`）产生 `.content(.text/.color)` 项，`Button` 包一层 `.effect(.tapTarget)`，`offset` 包一层 `.effect(.offset)`，容器按顺序拼接，最后到达宿主，交给 `ConsoleRenderer` 画成字符。点击时宿主对显示列表做命中测试找到 `ActionBox`。真实 SwiftUI 的 `DisplayList.Key`、`ViewResponder`（命中测试）、`DisplayList.ViewUpdater`（同步到 CALayer）都是这个模式。

---

## 第 8 课 · Transaction 与动画

`withAnimation` 只做一件事：把带 `animation` 的 `Transaction` 设为当前事务。

```
withAnimation(.linear(duration: 0.4)) { moved.toggle() }
  → StoredLocation.set 捕获 Transaction(animation: linear 0.4s) 并排队
  → flushTransactions：先把这个 transaction 写进图的 transaction 输入节点，再执行修改、拉取输出
  → _OffsetEffect 的值从 x=0 变成 x=16，AnimatableAttribute 发现「源值变了 + transaction 带动画」
     → 不输出 16，而是记下 from=0, to=16，按 time 节点插值，并 requestUpdate(at: now + 0.1)
  → 宿主看到 nextUpdateTime，就继续驱动后续帧，直到动画结束
```

`swift run MiniSwiftUIDemo 7`：

```
>>
    >>                t=100ms
        >>            t=200ms
            >>        t=300ms
                >>    t=400ms
动画结束，nextUpdateTime == nil，宿主不再请求新帧。
```

要点：

* 动画作用在**值**上，而不是视图上：任何遵守 `Animatable`（有 `animatableData: VectorArithmetic`）的东西都能插值。
* 中途改目标时从「当前显示的值」出发（真实 SwiftUI 会用 `combineAnimation` 做速度连续的叠加，spring 尤其明显）。
* 布局没有动：`offset` 是几何效果，只改显示列表（真实 SwiftUI 的 `GeometryEffect` 还会修改子视图的 `transform` 输入）。

---

## 第 9 课 · 修饰符

`Text("hi").padding()` 的类型是 `ModifiedContent<Text, _PaddingLayout>`：

```swift
static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
    Modifier._makeView(modifier: view[\.modifier], inputs: inputs) { inputs in
        Content._makeView(view: view[\.content], inputs: inputs)
    }
}
```

修饰符拿到「安装被修饰视图」的闭包，可以在调用前改 inputs（environment、几何、偏好需求），在调用后改 outputs（显示列表、布局）。自定义 `ViewModifier` 则和自定义视图一样走 body 规则，`content` 占位符通过 inputs 找回那个闭包（真实：`_ViewModifier_Content` + `BodyInput`）。`swift run MiniSwiftUIDemo 8` 演示了一个 `Card` 修饰符。

---

## 10. 原型刻意省略了什么

| 真实 SwiftUI 有 | MiniSwiftUI 的处理 |
|---|---|
| 用类型元数据 + 字段偏移扫描/注入 DynamicProperty，构建期即可区分 StaticBody/DynamicBody | 用 Mirror 扫描实例，推迟到首次求值；class 盒子代替指针写入 |
| AG 的偏移投影、页式内存、线程标记、可取消更新、调试服务器 | 每次投影新建节点；单线程；节点永不回收 |
| `compareValues` 基于类型布局（memcmp + Equatable） | Mirror 递归比较 |
| `IndirectAttribute` | 读容器值再读子输出的映射节点 |
| 显式 + 隐式组合 ID、懒加载、transition、`ViewList` 协议族 | 静态列表 + 按 ID 的动态列表 |
| 修饰多元视图时作用到每个元素 | 修饰后的视图在列表中占一个位置 |
| 坐标变换（`ViewTransform`）、安全区、对齐参考线、`layoutPriority`、尺寸缓存 | 绝对坐标、简化的栈算法 |
| Spring/Bezier 等动画、速度保持、动画合并、`Animatable` 的布局 | 线性/缓动、从当前值重新开始 |
| 手势系统、响应者链、无障碍、Observation | 只有按钮命中测试 |
| 多宿主、异步渲染、`Update.lock`、主线程断言 | 单宿主、同步 |

这些都是工程上的丰富与优化，**核心模型就是本教程的九课**。

---

## 11. 练习

1. **Toggle**：仿照 `Button` 写一个 `Toggle(isOn: Binding<Bool>)`，在父视图里用 `$flag` 传入。观察 Binding 里的闭包让子视图「每次都被认为变了」；思考真实 SwiftUI 为什么把 Binding 设计成 `location + transaction` 而不是闭包。
2. **Opacity**：实现 `.opacity(_:)`：新的 `DisplayList.Effect.opacity`，在渲染器里用 `·` 表示半透明；再让它可动画。
3. **ZStack 对齐**：给 `ZStack` 加 `alignment` 参数。
4. **if 也走动态列表**：让 `_ConditionalContent._makeViewList` 返回动态列表，使 `VStack { A; if c { B } }` 在 c 为 false 时不再为 B 保留间距。
5. **观察图**：给 `Graph` 写一个 `dumpDOT()`，把节点和边输出成 Graphviz，看看第 1 章的计数器建了哪些节点（提示：首次渲染时大约有 50 个规则节点运行）。
6. **对照阅读**：在 OpenSwiftUI 中找到 `StatePropertyBox.update`、`DynamicBody.updateValue`、`Layout.makeStaticView`，逐行对比 MiniSwiftUI 的对应实现，列出差异。
