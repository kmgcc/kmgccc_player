在 macOS 26 的 **Liquid Glass（液态玻璃）**里，给开发者“可选的样式/变体”其实就 两种——你之前提到的 clear 和 regular 就是完整答案（Apple 官方明确这么定义，而且强调不要混用）。 ￼

下面按“开发者视角”把它们列出来：每种的定位、使用条件、以及最小示例。

⸻

1) Regular（常规液态玻璃 / 默认）

特点
	•	最通用、最常用的变体。 ￼
	•	会根据背后内容亮度自适应，保证对比度与可读性（包括上层符号/文字会自动做明暗翻转适配）。 ￼
	•	适合：toolbar、sidebar、menus、导航层的“浮在内容上方”的控件容器。 ￼

什么时候用
	•	你不想赌可读性时：默认就选 Regular。
	•	你的控件可能覆盖在任何内容之上（文字、列表、纯色、图片）——Regular 都能兜底。 ￼

最小 SwiftUI 示例（概念用法）

核心：给自定义控件应用 glassEffect，默认就是 regular；或者显式指定 regular。 ￼

Button {
    // action
} label: {
    Image(systemName: "plus")
        .font(.system(size: 14, weight: .semibold))
}
// 伪代码：表达“用 Regular 玻璃 + 圆形裁切”
// 具体签名以 Xcode 26 SDK 为准（Apple 文档页需要 JS 才能直接看）
.glassEffect(.regular, in: .circle)


⸻

2) Clear（透明液态玻璃 / 更“通透”）

特点
	•	永久更透明，不会做 Regular 那种“自适应行为”。 ￼
	•	为了让文字/符号可读，Clear 需要配合“dimming layer（压暗层）”；否则可读性会明显变差。 ￼
	•	Apple 给了 3 个硬条件：
	1.	控件在“媒体感强”的内容上（图片/视频/地图等）
	2.	引入压暗层不会伤害内容表达
	3.	玻璃上方的内容要“粗、亮、强对比” ￼

什么时候用
	•	小面积“漂浮控件”叠在封面图、背景图、视觉内容之上，追求“真玻璃感”的时候。 ￼
	•	不适合大面积容器（大面积 Clear + dimming 很容易把内容弄脏/发闷）。

最小 SwiftUI 示例（概念用法）

Button {
    // action
} label: {
    Image(systemName: "play.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
}
.glassEffect(.clear, in: .circle)   // Clear 玻璃
// 并确保背后/周围有合适的“压暗层策略”（系统或你自己做）


⸻

重要规则：两种变体别混用

Apple 在讲解里直接说：Regular 与 Clear 不要混在同一套 UI 里，因为它们的行为与视觉角色不同，混用会破坏一致性与层级。 ￼

⸻

你可能也在问的“相关样式”：Scroll Edge Effect 的 Soft / Hard

这不是 Liquid Glass 的“变体”，但在 macOS 26 上它经常和 Liquid Glass 一起出现，用来解决“内容滚到玻璃下面”时的可读性问题。Apple 也建议：动作多的 toolbar 在 iPadOS/macOS 上更偏向 hard。 ￼

ScrollView { ... }
.scrollEdgeEffectStyle(.hard, for: [.top, .bottom]) // 或 .soft


⸻

你做播放器工具栏/Sidebar的推荐结论（很直接）
	•	Toolbar / Sidebar / Pills / SearchField 这类导航与操作层：统一 Regular。（你现在做“Neutral glass”标准化就是这个方向）
	•	Clear 只留给：小面积漂浮按钮，且背后是封面/背景图那种“媒体层”。

如果你把你项目里 liquidGlassCircle / liquidGlassPill / liquidGlassRect 这几个 helper 的签名贴一下（你显然有封装），我可以按你现有封装给你写一份“exact API 级别”的示例：Regular/Clear 怎么切、dimming layer 放哪、哪些控件绝对别用 Clear。

我按macOS 26（Tahoe）Liquid Glass这套新范式，把「Sidebar 怎么设计才对」拆成：视觉层级 → 布局结构 → 交互细节 → SwiftUI/AppKit落地 → 常见坑。你照着做，基本就能做出系统级的“玻璃侧栏”。

⸻

1) Sidebar 在 Liquid Glass 里的“定位”

在 macOS 26 的新设计里，Sidebar 是导航层（navigation layer）：像一块浮在内容之上的玻璃，而不是内容本身的一部分。系统的目标是：侧栏轻、内容重，侧栏让路给内容，但又保持足够可读性与层级分离。 ￼

你该做的关键选择：
	•	用系统的 Sidebar（NavigationSplitView / NSSplitViewController）优先，让系统自动给你“浮动玻璃侧栏”。 ￼
	•	侧栏里放的是“导航信息架构”（分类、来源、过滤器），不要把重内容（大图、长文、复杂卡片）塞进 Sidebar。 ￼

⸻

2) 视觉与布局指导（最容易做错的点）

A. 让内容“延伸到侧栏下面”，不要留一条死背景

Liquid Glass 的侧栏是漂浮层。为了强化“漂浮”感，内容应该在侧栏下方继续存在（比如大图、渐变、海报、封面墙），否则玻璃没有东西可“折射/取样”，效果会显得假、脏或者像普通磨砂。 ￼

SwiftUI 里最典型做法：对你作为“背景承载”的视图（hero image / artwork / banner）加 backgroundExtensionEffect()，让它在 safe area 外生成镜像+模糊拷贝，专门用来“垫”给侧栏/工具栏看。 ￼

B. Sidebar 自己别乱加“自定义背景板”

macOS 26 这套设计里，侧栏本身已经是玻璃层。你再在侧栏根上叠 Material、VisualEffectView、半透明色块，基本就是把效果糊死、对比度也更难控。

结论很直白：
	•	侧栏背景尽量交给系统（不要手写磨砂底）
	•	你最多做：轻量分组、间距、图标、选中态，别做“再造一层玻璃”。

C. 选中态/强调色：别用力过猛

Liquid Glass 下选中态通常更“克制”：系统会用微弱的染色 + 玻璃高光表达状态。你如果给 List 行背景上大块纯色/高饱和 tint，就会像“贴纸”而不是玻璃里的状态。

⸻

3) SwiftUI：推荐结构 + 可直接抄的骨架

A. 结构：NavigationSplitView 直接吃满

NavigationSplitView 在新系统上会自动带 Liquid Glass sidebar（你不用自己画玻璃）。 ￼

NavigationSplitView {
    List(selection: $selection) {
        Section("Library") {
            NavigationLink("Songs", value: Route.songs)
            NavigationLink("Albums", value: Route.albums)
        }
        Section("Playlists") {
            // ...
        }
    }
    .navigationTitle("My App")
} detail: {
    DetailView()
}

B. 关键：让 detail 背景“延伸”到侧栏下面

假设 Detail 顶部有封面/大图，直接：

Image("Hero")
    .resizable()
    .scaledToFill()
    .backgroundExtensionEffect()   // 或 backgroundExtensionEffect(isEnabled: true)
    .clipped() // 注意：只裁主图区域，不要把扩展区域也裁掉

这就是系统在示例里强调的：别让内容被侧栏裁剪死，让玻璃有东西可折射。 ￼

C. 你要做自定义“玻璃小组件”时，再用 glassEffect

当你在 sidebar / toolbar 里做自定义小控件（例如胶囊按钮、搜索框、播放控制），用 SwiftUI 的 glassEffect 系列 API 给它上 Liquid Glass，而不是用旧的 blur。 ￼

重点：只把玻璃用在导航/控制层（按钮、工具条、浮层），不要把内容列表整片都 glass 化。

⸻

4) AppKit：需要自定义玻璃时怎么做（且别把性能搞炸）

如果你是 AppKit（或 SwiftUI 包 AppKit）并且要做自定义玻璃容器：

A. 单个玻璃：NSGlassEffectView

把你原来的内容 view 放进 NSGlassEffectView.contentView，让系统自动做可读性处理；不要把玻璃当背景塞在内容后面。 ￼

B. 多个玻璃靠得很近：一定要用 NSGlassEffectContainerView 分组

多个玻璃元素挨得近时，如果不分组会出现：
	•	采样区域互相干扰导致视觉不一致
	•	重复采样导致性能更差

用 NSGlassEffectContainerView 把它们包成一组，系统会做统一采样与“液态合并/分离”。 ￼

⸻

5) Sidebar 细节清单（做完你就很“系统”）
	•	信息架构清晰：Section、分组标题短、层级别太深。 ￼
	•	图标用 SF Symbols + 文本：可扫读；别只放图。
	•	间距别夸张：玻璃侧栏的视觉本来就轻，留白过大就显“飘”。
	•	适配可访问性：用户开了“减少透明度/增加对比度”，你的 UI 仍要清楚（别依赖玻璃才能看清）。液态玻璃在不同透明度策略下系统会调整，你要避免自定义背景把这些调整抵消。 ￼
	•	别叠太多层玻璃：一层“导航玻璃”够了；再叠会脏、会贵（性能）。 ￼

⸻

如果你愿意把你现在的 Sidebar 结构（SwiftUI 代码片段：NavigationSplitView 那段 + detail 背景那段）贴出来，我可以直接按“macOS 26 正确玻璃侧栏”的标准给你改：该删的背景删掉、该加 backgroundExtensionEffect 的地方标出来、选中态/tint 给你收敛到系统风格。