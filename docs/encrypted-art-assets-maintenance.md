# 艺术素材加密保护说明与维护指南

## 1. 目标与安全边界

艺术素材加密保护用于降低 App 被解包后直接复制原创图片素材的风险。当前保护对象包括 `BKThemes` 文件夹素材，以及从 `Assets.xcassets` 中迁出的高价值原创视觉素材。

这不是绝对 DRM，也不承诺抵御专业逆向。当前安全边界是：

- Release bundle 中不保留已保护素材的明文 PNG/JPG/WebP。
- App 运行时按需读取 `.kmgasset`，在内存中认证解密并解码为 `CGImage` / `NSImage`。
- 解密后的明文图片数据不写入磁盘。
- 本地开发母版素材保留在固定私有目录中，但不提交 Git，不进入 Release bundle。

维护原则是“一个素材只保留一个母版来源”。迁移后的 xcassets 原图统一放在 `PrivateArtSources/XCAssetsOriginals/`；旧的 `myPlayer2/Resources/CassetteSkin/` 明文副本已移除，避免多路径维护。

## 2. 当前加密机制

加密使用 Apple CryptoKit 的 `AES.GCM`。这是 AEAD 算法，密文带认证标签；文件被篡改、截断或密钥不匹配时，运行时解密会失败并 fallback，不会静默显示错误图像。

`.kmgasset` 文件结构：

| 字段 | 长度 | 说明 |
| --- | ---: | --- |
| magic | 8 bytes | 固定 `KMGASSET` |
| version | 1 byte | 当前为 `1` |
| algorithm | 1 byte | 当前为 `1`，表示 AES-GCM-256 |
| flags | 1 byte | 保留，当前为 `0` |
| nonceLength | UInt16 big-endian | nonce 长度 |
| tagLength | UInt16 big-endian | GCM auth tag 长度 |
| ciphertextLength | UInt64 big-endian | 密文长度 |
| nonce | variable | AES-GCM nonce |
| ciphertext | variable | 图片原始数据密文 |
| auth tag | variable | AES-GCM 认证标签 |

这不是 Base64、XOR 或改后缀。运行时会校验 magic、version、algorithm 和长度，再执行 AES-GCM 认证解密。

密钥没有作为单一明文字符串写入源码。加密脚本和运行时 loader 使用多段 `UInt8` 材料，运行时组合后结合固定上下文字符串做 `SHA256` 派生。Debug 可用 `KMG_ART_ASSET_KEY_HEX` 覆盖开发密钥；Release 不依赖该环境变量。

## 3. 目录结构与相关文件

本地母版素材目录：

- `BKThemes/Backgrounds/`
- `BKThemes/Mask/`
- `BKThemes/Shapes/`
- `PrivateArtSources/XCAssetsOriginals/`

加密输出目录：

- `EncryptedArtAssets/BKThemes/Backgrounds/`
- `EncryptedArtAssets/BKThemes/Mask/`
- `EncryptedArtAssets/BKThemes/Shapes/`
- `EncryptedArtAssets/XCAssets/`

核心文件：

- `scripts/encrypt_art_assets.swift`：加密工具。
- `scripts/encrypted_asset_allowlist.json`：允许迁移的 xcassets allowlist。
- `EncryptedArtAssets/manifest.json`：加密产物清单。
- `myPlayer2/Services/Theme/EncryptedArtAssetLoader.swift`：运行时 loader 和 SwiftUI 包装。
- `myPlayer2/Resources/Audio/`：普通 bundle 音频资源目录，不属于艺术图片加密流程。
- `myPlayer2/Views/NowPlaying/BKThemeAssets.swift`：BKThemes 统一入口。
- `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift`：磁带皮肤和相关视觉素材调用端。
- `myPlayer2/Services/Library/PlaylistArtworkGenerator.swift`：播放列表默认封面底图调用端。
- `myPlayer2/Views/Settings/About/AboutSettingsView.swift`：关于页彩蛋图调用端。
- `kmgccc_player.xcodeproj/project.pbxproj`：`BKArt` target 复制 `EncryptedArtAssets`，主 App 复制 `BKArt.bundle`。

当前没有自动 Build Phase 运行加密脚本。构建前需要手动运行脚本并提交加密产物。

## 4. 已加密素材清单

当前 `EncryptedArtAssets/manifest.json` 记录 46 个条目：31 个 `bkThemes`，15 个 `xcassets`。算法为 `AES.GCM.256`，formatVersion 为 `1`。

| 分类 | 原始路径 | 加密后路径 | 数量 | 当前用途 | 调用端 | 状态 |
| --- | --- | --- | ---: | --- | --- | --- |
| BKThemes Backgrounds | `BKThemes/Backgrounds/bk1.png`, `bk2.png` | `EncryptedArtAssets/BKThemes/Backgrounds/*.kmgasset` | 2 | BKArt 背景图轮换 | `BKThemeAssets`, `BKArtBackgroundView` | 已加密 |
| BKThemes Mask | `BKThemes/Mask/frame_00.png` 到 `frame_17.png` | `EncryptedArtAssets/BKThemes/Mask/*.kmgasset` | 18 | BKArt 转场 mask 动画帧 | `BKThemeAssets`, `BKArtBackgroundView` | 已加密 |
| BKThemes Shapes | `BKThemes/Shapes/shape1.png` 到 `shape11.png` | `EncryptedArtAssets/BKThemes/Shapes/*.kmgasset` | 11 | BKArt 和 Home ambient shapes | `BKThemeAssets`, `BKArtBackgroundView`, `HomeAmbientShapesBackground` | 已加密 |
| XCAssets Playlist Covers | `PrivateArtSources/XCAssetsOriginals/cov1.imageset` 到 `cov4.imageset` | `EncryptedArtAssets/XCAssets/cov1.kmgasset` 到 `cov4.kmgasset` | 4 | 播放列表默认封面底图 | `PlaylistArtworkGenerator` | 已加密 |
| XCAssets Cassette Skin | `PrivateArtSources/XCAssetsOriginals/tape*.imageset`, `darkhole.imageset`, `lighthole.imageset`, `kmglook.imageset`, `seasons.imageset` | `EncryptedArtAssets/XCAssets/*.kmgasset` | 10 | 磁带皮肤、孔洞、标识、默认唱片图 | `KmgcccCassetteSkin` | 已加密 |
| XCAssets About Easter Egg | `PrivateArtSources/XCAssetsOriginals/jntm.imageset` | `EncryptedArtAssets/XCAssets/jntm.kmgasset` | 1 | 关于页彩蛋图 | `AboutSettingsView` | 已加密 |

已迁移 xcassets logicalName：

- `XCAssets/cov1` 到 `XCAssets/cov4`
- `XCAssets/darkhole`
- `XCAssets/jntm`
- `XCAssets/kmglook`
- `XCAssets/lighthole`
- `XCAssets/seasons`
- `XCAssets/tape`
- `XCAssets/tapedark`
- `XCAssets/tapegray`
- `XCAssets/tapemask`
- `XCAssets/tapeoutline`
- `XCAssets/tapepaper`

## 5. Assets.xcassets 审计状态

不要全量加密 `Assets.xcassets`。原因是 asset catalog 中包含颜色、音频 dataset、低风险 UI 图、疑似 unused 图片等不同类型资源；全量迁移会扩大调用端改动，也容易破坏 SwiftUI 静态资源、template rendering、scale 或 appearance 行为。

审计状态：

| Asset 名称 | 类型 | 是否被引用 | 引用位置 | 是否原创艺术素材 | 本轮处理 |
| --- | --- | --- | --- | --- | --- |
| `AccentColor` | colorset | 是 | Xcode global accent | 否 | skip-color |
| `EmptyLyric` | imageset | 是 | `LyricsPanelView`, `AboutSettingsView` | 普通空状态插图 | keep-xcassets |
| `cov1` 到 `cov4` | imageset | 是 | `PlaylistArtworkGenerator` | 是，默认封面视觉素材 | migrate |
| `darkhole` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带皮肤素材 | migrate |
| `jntm` | imageset | 是 | `AboutSettingsView` | 是，关于页彩蛋图 | migrate |
| `kmglook` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带皮肤标识 | migrate |
| `lighthole` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带皮肤素材 | migrate |
| `seasons` | imageset | 是 | `KmgcccCassetteSkin` | 是，默认唱片视觉素材 | migrate |
| `snowflake1` 到 `snowflake5` | imageset | 未发现运行时引用 | 无 | 未确认 | unused-candidate |
| `tape`, `tapedark` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带主体 | migrate |
| `tapegray` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带皮肤灰色层 | migrate |
| `tapemask` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带 mask | migrate |
| `tapeoutline` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带描边 | migrate |
| `tapepaper` | imageset | 是 | `KmgcccCassetteSkin` | 是，磁带纸面层 | migrate |
| `youdowhat` | wav | 是 | `EasterEggSFXService` | 非图片，彩蛋音频 | keep-bundle-audio |
| `youdowhatreversed` | wav | 是 | `EasterEggSFXService` | 非图片，彩蛋音频 | keep-bundle-audio |

迁移后，彩蛋音频不再依赖 `Assets.xcassets` dataset；源文件位于 `myPlayer2/Resources/Audio/youdowhat.wav` 和 `myPlayer2/Resources/Audio/youdowhatreversed.wav`。当前 Xcode file-system synchronized resources 会将它们作为普通 bundle 文件复制到 `.app/Contents/Resources/` 根目录；调用端是 `AboutSettingsView` 直接调用 `EasterEggSFXService.shared.playRandomIfAllowed()`，服务内部优先通过 `Bundle.main.url(forResource:withExtension:)` 加载，并保留 `Audio` 子目录 fallback。彩蛋音频不通过 `NotificationCenter` 间接转发，不通过 `EncryptedAssetImages`，不通过 `EncryptedArtAssetLoader`。`myPlayer2/Assets.xcassets` 中如仍有本地旧 dataset，只能视为未追踪的历史来源，不作为运行时资源管理；Xcode target 已显式排除 `youdowhat.dataset` 和 `youdowhatr.dataset`。`snowflake` 系列仅标记为 unused candidate，不在本轮删除。

## 6. 非图片资源不属于本加密流程

当前艺术素材加密只覆盖图片资源：`png`、`jpg` / `jpeg`、`webp`，以及项目未来如需使用的 `heic`。加密脚本只会递归处理这些图片扩展名；xcassets 迁移也只接受 allowlist 中 `.imageset` 内的图片文件。

以下资源明确不进入 `EncryptedArtAssetLoader`，也不应出现在 `EncryptedArtAssets/manifest.json` 中：`wav`、`mp3`、`m4a`、`aiff`、`caf`、`json`、`ttml`、`js`、`css`、`html`。

彩蛋音效 `youdowhat.wav` 和 `youdowhatreversed.wav` 应作为普通 bundle 音频资源管理，当前源路径为 `myPlayer2/Resources/Audio/`。关于页触发彩蛋时直接调用 `EasterEggSFXService.shared.playRandomIfAllowed()`；音频服务内部加载方式优先为：

```swift
Bundle.main.url(forResource: "youdowhatreversed", withExtension: "wav")
```

`.gitignore` 可以忽略原始图片艺术素材目录，例如 `BKThemes/`、`PrivateArtSources/` 和迁移后的本地 asset catalog 母版，但不能误伤运行时必须提交的音频资源。运行时音频应位于可追踪目录，提交前用 `git status --short myPlayer2/Resources/Audio` 或 `git ls-files myPlayer2/Resources/Audio` 确认。

如果未来要加密音频，应单独设计 `EncryptedAudioAssetLoader`，明确音频格式、流式播放、缓存、授权和 fallback 策略；不要复用图片 loader 强行处理音频。

## 7. 加密生成流程

### A. 修改或新增母版素材

1. 修改 `BKThemes/` 或 `PrivateArtSources/XCAssetsOriginals/` 下的本地母版。
2. 如新增 xcassets 艺术素材，先加入 `scripts/encrypted_asset_allowlist.json`。
3. 运行加密脚本。
4. 检查 `EncryptedArtAssets/manifest.json` 是否更新。
5. 提交 `.kmgasset`、manifest、allowlist 和代码修改。
6. 不提交本地母版原图。

推荐命令：

```sh
scripts/encrypt_art_assets.swift \
  --input BKThemes \
  --output EncryptedArtAssets \
  --logical-root BKThemes \
  --allowlist scripts/encrypted_asset_allowlist.json
```

强制重加密：

```sh
scripts/encrypt_art_assets.swift \
  --input BKThemes \
  --output EncryptedArtAssets \
  --logical-root BKThemes \
  --allowlist scripts/encrypted_asset_allowlist.json \
  --force
```

脚本行为：

- `BKThemes`：按目录递归处理支持的图片文件，当前为 `png`、`jpg` / `jpeg`、`webp`、`heic`。
- `XCAssets`：只处理 allowlist 中列出的 `.imageset`。
- `sourceKind` 写入 `bkThemes` 或 `xcassets`。
- `xcassets` 条目写入 `originalAssetName`、`originalPath`、`appearance`、`scale`。
- 若原图 sha256 未变化且加密文件存在，则跳过。

当前迁移的 xcassets 都是单图 universal imageset，没有 dark/light 或多 scale 明文变体。若以后遇到 appearance 或 scale 变体，必须保留为多份 logicalName，不得丢失差异。

### B. 构建时

Release bundle 应只包含 `.kmgasset` 和 manifest。`BKThemes`、`PrivateArtSources`、已迁移 imageset 原图、旧 `Resources/CassetteSkin` 明文副本都不应进入 bundle。

当前没有自动 Build Phase。发布前需要手动运行加密脚本，并确认 `BKArt.bundle` 中 `EncryptedArtAssets` 是最新的。

### C. App 运行时

1. BKThemes 调用端通过 `BKThemeAssets` 请求 logicalName。
2. 已迁移 xcassets 调用端通过 `EncryptedArtAssetLoader.shared.xcAssetImage(named:maxPixel:)` 或 `EncryptedAssetImages.image(named:maxPixel:)` 请求资源。
3. loader 定位 `EncryptedArtAssets/<logicalName>.kmgasset`。
4. loader 校验 header 并用 AES-GCM 认证解密。
5. loader 用 ImageIO 解码和下采样。
6. loader 将 `CGImage` 写入 `NSCache`。
7. 调用端得到 `NSImage` 或 SwiftUI `Image`。
8. 失败时记录主题日志并返回 fallback，不崩溃。

## 8. App 运行时加载流程

职责边界：

- `EncryptedArtAssetLoader`：加密文件读取、格式校验、解密、图片解码、底层缓存、SwiftUI 包装。
- `BKThemeAssets`：BKThemes 的业务枚举、Debug 明文 fallback、下采样、mask alpha 处理。
- `KmgcccCassetteSkin`：只负责磁带皮肤布局和渲染，不再直接读取明文皮肤 PNG。

示例：

```swift
EncryptedArtAssetLoader.shared.xcAssetImage(named: "kmglook", maxPixel: 800)
EncryptedAssetImages.image(named: "seasons", maxPixel: 1600)
```

## 9. Git 与本地素材管理

`.gitignore` 规则：

```gitignore
/BKThemes/
/PrivateArtSources/
```

原始明文图片素材保留在本地，不提交 Git。加密后的 `.kmgasset`、`manifest.json`、allowlist、脚本、loader 和调用端代码需要提交。运行时音频不属于原始图片素材，必须提交普通 bundle 文件，例如 `myPlayer2/Resources/Audio/youdowhatreversed.wav`。

如果发现原始明文素材已被 Git 追踪，只从索引移除，不删除本地文件：

```sh
git ls-files | grep 'BKThemes'
git ls-files | grep 'PrivateArtSources'
git rm --cached <path>
```

旧的 `myPlayer2/Resources/CassetteSkin/` 是重复明文来源，已移除。不要重新引入该目录；磁带皮肤母版统一维护在 `PrivateArtSources/XCAssetsOriginals/`。

不要提交真实密钥、临时解密产物、DerivedData 或构建中间目录。

## 10. 发布前验证清单

- `.app` / `BKArt.bundle` 内没有 `BKThemes/**/*.png`。
- `.app` / `BKArt.bundle` 内没有 `PrivateArtSources`。
- `.app` / `BKArt.bundle` 内没有已迁移 xcassets 原图，例如 `cov1.png`、`jntm.png`、`seasons.jpg`、`tapeskin*.png`、`lighthole.png`。
- `.app` / `BKArt.bundle` 内有 46 个 `.kmgasset` 和 `EncryptedArtAssets/manifest.json`。
- `Assets.car` 中不包含已迁移 asset 名称，只允许保留 `EmptyLyric`、`snowflake*`、颜色和 dataset。
- `.app/Contents/Resources/` 中包含 `youdowhat.wav` 和 `youdowhatreversed.wav`。
- `Bundle.main.url(forResource: "youdowhatreversed", withExtension: "wav")` 在 Debug 和 Release 中都返回非 nil。
- `.kmgasset` 不能被 Preview/Finder 直接作为图片打开。
- BKArt 背景、mask、shape 正常显示。
- 磁带皮肤、孔洞、`kmglook`、`seasons` 默认图、播放列表默认封面正常显示。
- 关于页彩蛋触发后图片正常显示，彩蛋音效正常播放；找不到音频时只记录日志，不崩溃。
- 缺失 `.kmgasset` 时 App 不崩溃，有主题日志和 fallback。
- 篡改 `.kmgasset` 后 AES-GCM 认证失败，并 fallback。
- 重复显示同一素材命中缓存，不反复解密。
- Release 模式不依赖本地明文素材。

检查示例：

```sh
xcodebuild \
  -project kmgccc_player.xcodeproj \
  -scheme kmgccc_player \
  -configuration Debug \
  -derivedDataPath .derivedDataAssetEncryption \
  CODE_SIGNING_ALLOWED=NO \
  build

app=".derivedDataAssetEncryption/Build/Products/Debug/kmgccc_player.app/Contents/Resources"

find "$app" -type f \( \
  -name 'cov1.png' -o -name 'cov2.png' -o -name 'cov3.png' -o -name 'cov4.png' \
  -o -name 'jntm.png' -o -name 'seasons.jpg' -o -name 'tapeskin*.png' \
  -o -name 'lighthole.png' -o -name 'Untitled_Artwork 4.png' \
\)

find "$app" -path '*/EncryptedArtAssets/*' -name '*.kmgasset' | wc -l
find "$app" -maxdepth 1 -type f -name 'youdowhat*.wav' -print
xcrun assetutil --info "$app/Assets.car" | rg 'cov1|cov2|cov3|cov4|darkhole|jntm|kmglook|lighthole|seasons|tape|tapedark|tapegray|tapemask|tapeoutline|tapepaper'
```

最后一个 `assetutil` 命令不应输出已迁移 asset 名称。

## 11. 后续维护规范

### 新增 BKThemes 素材

1. 放入本地 `BKThemes/`。
2. 更新调用端 logicalName 枚举。
3. 运行加密脚本。
4. 检查 manifest。
5. 提交加密产物，不提交原图。

### 新增 xcassets 艺术素材

1. 先审计是否真实运行时引用。
2. 只迁移确认在用且属于原创艺术/视觉资产的图片。
3. 将母版放入 `PrivateArtSources/XCAssetsOriginals/<name>.imageset`。
4. 加入 `scripts/encrypted_asset_allowlist.json`。
5. 运行加密脚本。
6. 将调用端改为 `EncryptedArtAssetLoader` 或 `EncryptedAssetImages`。
7. 确认 `Assets.car` 不含该 asset 名称。

### 替换素材

1. 保持 logicalName 不变。
2. 替换唯一母版路径中的原图。
3. 重新运行加密脚本。
4. 检查 manifest hash 变化。
5. 回归测试显示效果。

### 删除素材

1. 先确认无调用引用。
2. 从 allowlist 和调用端移除。
3. 删除对应 `.kmgasset`。
4. 更新 manifest。
5. 本地母版是否保留由素材管理决定，但不要误删仍在用的唯一母版。

### 特殊资源

- `AccentColor`、colorset：skip-color。
- dataset / 音频：不属于图片加密范围；运行时音频放在普通 bundle 资源目录。
- PDF/vector/template image：迁移前必须确认不会破坏矢量缩放或 template tint；不确定时标记 `needs-manual-check`。
- dark/light appearance：必须输出不同 logicalName，如 `XCAssets/name/light`、`XCAssets/name/dark`。
- 1x/2x/3x：不得降低 Retina 清晰度；必要时保留多份或选择最高质量源图。
- unused candidate：只记录，不和加密迁移同轮删除。

## 12. 常见问题排查

### 图片显示为空白

检查 logicalName 是否有对应 `.kmgasset`，并查看主题日志中的 `EncryptedArtAssetLoader` 错误。Debug 下可设置 `KMG_USE_PLAIN_ART_ASSETS=0` 复现 Release 加密路径。

### Debug 能显示，Release 不显示

通常是 Debug 走了本地明文 fallback，Release 缺少加密产物。检查 `EncryptedArtAssets` 是否复制进 `BKArt.bundle`，并确认 manifest 包含对应 logicalName。

### Assets.car 中仍有已迁移素材

说明对应 `.imageset` 仍在 `myPlayer2/Assets.xcassets` 中，或被其他 asset catalog 引入。把母版移到 `PrivateArtSources/XCAssetsOriginals/`，不要保留在 target asset catalog 内。

### bundle 中仍有明文 PNG/JPG

检查 Copy Bundle Resources、file-system synchronized group、旧目录副本和 Build Phase。不要恢复 `myPlayer2/Resources/CassetteSkin/` 这类重复明文路径。

### 解密失败

确认生成和运行时使用同一密钥。修改密钥后，所有旧 `.kmgasset` 都必须重新生成。

### 性能变差

检查是否不断改变 `maxPixel` 导致 cache key 变化。`EncryptedArtAssetLoader` 和 `BKThemeAssets` 都有缓存；mask 动画帧应预热或复用，不应逐帧重新解密。

## 13. 后续改进建议

- 增加 manifest 校验脚本，扫描缺失、过期、篡改和 bundle 明文泄漏。
- 增加 Release 构建检查，发现已迁移素材出现在 `Assets.car` 或 bundle 明文路径时失败。
- 为 Debug 增加 loader cache hit / decrypt counter。
- 继续按审计结果评估 `EmptyLyric` 是否需要迁移；当前保留在 xcassets。
