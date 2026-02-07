<p align="center">
  <img src="screenshots/Icon-iOS-Default-1024x1024@1x.png" width="192" alt="kmgccc_player Icon" />
</p>

<h1 align="center">kmgccc_player</h1>

<p align="center">
  面向 <strong>macOS 26</strong> 的本地音乐播放器<br>
  原生开发、专注美学，致力于沉浸式且富有特色的播放体验
</p>


> [!WARNING]
> kmgccc_player 为个人项目，可能存在 Bug、未完成特性或行为变动。  
> 不建议在重要环境中作为唯一播放器使用，欢迎通过官网表单或者 Issue 反馈问题。也欢迎提出你的意见和创意～
> 代码使用 AI 生成，可能存在问题。

[看看 kmgccc_player](https://player.kmgccc.cn)

## Clone

本项目使用 Git submodule 管理 AMLL integration 源码。

**推荐 clone 方式：**

```bash
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
```

如果已经普通 clone，需要初始化 submodule：

```bash
git submodule update --init --recursive
```

或者运行 bootstrap 脚本，它会自动检查并初始化：

```bash
./scripts/bootstrap.sh
```

AMLL integration 源码位于：

```
applemusic-like-lyrics-kmgcccplayer-integration/
```

如果该目录为空或缺少文件，请在构建前初始化 submodule。

> [!NOTE]
> GitHub "Download ZIP" **不会**包含 submodule 内容。如需从源码构建，请使用 `git clone --recurse-submodules`。

## 构建与运行 (Build)

由于使用了 macOS 26 的新系统特性，构建环境要求如下：

- **系统要求**：macOS 26.0 或更新版本  
- **开发工具**：建议使用最新版本的 Xcode

**构建步骤：**

1. 克隆本仓库代码（参见上方 Clone 说明，确保包含 submodule）  
2. 使用 Xcode 打开 `kmgccc_player.xcodeproj`  
3. 打包外部工具（如需完整功能）：
   - **LDDC Server**：使用脚本打包，输出到 `Tools/lddc-server`
   - **ncmdump**：从 [taurusxin/ncmdump](https://github.com/taurusxin/ncmdump) 下载 arm64-compatible macOS binary，放入 `Tools/ncmdump/`
   - **sacad**：从 [desbma/sacad](https://github.com/desbma/sacad) 下载或通过 `cargo install sacad` 安装
   - **QQMusic helper**：运行 `kmgccc_player/Resources/Tools/qqmusic-helper/build-universal.sh` 生成并 ad-hoc sign bundled macOS binary。app 只调用 `Resources/Tools/qqmusic-helper/qqmusic-helper`，不依赖本机 Python/venv。
4. 选择 `kmgccc_player` Scheme 并运行。公开构建不依赖 checkout 之外的资源；缺失可选增强资源时会自动使用公开 fallback，不会导致构建失败。

公开构建脚本会显式关闭外部资源注入：

```sh
./scripts/build_public.sh Debug
./scripts/build_public.sh Release
```

## 第三方运行时

本项目内置少量第三方运行时组件，用于元数据、封面、歌词和 AMLL 渲染等功能。Release 构建默认面向 Apple Silicon arm64。
第三方工具需要先构建出二进制，仓库内附有打包构建脚本。

## 注意事项

- app的数据文件存默认放在`/Users/username/Music/kmgccc_player Library`中, 删除、替换 app 不会删除数据文件

- 可以使用 `AMLL TTML Tool` 手动编辑 ttml 格式的歌词，操作更精准且可以启用 amll 的高级功能如背景歌词、对唱歌词。
项目地址：https://github.com/amll-dev/amll-ttml-tool 
在线使用：https://amll-ttml-tool.stevexmh.net/ 
也欢迎给 AMLL DB 贡献歌词。

## 致谢

本项目在开发过程中使用并修改了以下开源项目：

- **applemusic-like-lyrics (AMLL)**  
  提供歌词渲染能力，实现类 Apple Music 的歌词显示效果。  
  https://github.com/amll-dev/applemusic-like-lyrics  
  AMLL DB 歌词库：https://github.com/amll-dev/amll-ttml-db

- **LDDC (Lyrics Data Digging Core)**  
  提供歌词获取与匹配能力。  
  https://github.com/chenmozhijin/LDDC

- **apple-audio-visualization**  
  提供音频频谱分析与可视化算法，本项目在播放界面与磁带视图中使用并修改了其部分实现。  
  https://github.com/taterboom/apple-audio-visualization

- **ncmdump**  
  提供 NCM 格式解密能力，支持导入网易云音乐加密文件。  
  https://github.com/taurusxin/ncmdump

- **sacad**  
  提供专辑封面搜索与下载能力。  
  https://github.com/desbma/sacad

- **QQMusicApi**  
  提供 QQ 音乐元数据与封面候选查询能力。  
  https://github.com/L-1124/QQMusicApi

- **WhatsNewKit**  
  提供应用更新说明展示组件。  
  https://github.com/SvenTiigi/WhatsNewKit


## 美术素材版权声明

除代码及另有说明的第三方内容外，本项目相关的美术素材，包括但不限于界面插画、UI 装饰、皮肤、贴图、角色设计、图形元素、图像资源及其他视觉素材，均为作者原创作品，其著作权及其他相关权利均由作者保留。

前述美术素材**不构成本项目开源代码的一部分**，**亦不适用本仓库所采用的 AGPL-3.0 或其他任何开源许可证**。任何个人或组织，未经作者事先书面授权，不得以**任何形式**对该等素材进行复制、转载、分发、修改、改编、商用、二次创作、数据集收录、抓取、提取，或用于机器学习、生成式 AI 训练、微调、推理输入集构建及其他类似用途。

本仓库当前不包含上述原创美术素材。任何需要相关素材的使用者，均应自行制作或另行取得作者的明确书面许可。

保留一切权利。
Copyright © kmg. All rights reserved.

## 许可证 (License)

本项目为开源软件，**代码** 基于 **GNU Affero General Public License v3.0 (AGPL-3.0)** 发布。  
项目中所使用的第三方组件遵循其各自的开源许可证，详见应用内 About 页面及 `Licenses` 目录。
