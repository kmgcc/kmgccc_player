# 艺术素材加密保护说明与维护指南

## 1. 目标与安全边界

艺术素材加密保护的目标是防止 App 被解包后直接复制原创图片素材。当前重点保护 `BKThemes` 下的艺术背景、遮罩动画帧和形状素材，避免 Release 产物中继续包含可直接打开的 PNG 文件。

这套机制不是绝对 DRM，也不承诺防住专业逆向。它的安全边界是：

- App bundle 中不应出现受保护素材的明文 PNG/JPG/WebP。
- App 运行时按需读取 `.kmgasset` 文件并在内存中解密。
- 解密后的明文图片数据不写入磁盘，只在内存中解码为 `CGImage` 并进入图片缓存。
- 本地开发母版素材继续保留在 `BKThemes/`，但不提交 Git，也不进入 Release bundle。

因此，这套机制解决的是“解包后直接复制图片文件”的风险，而不是对运行时内存、二进制逆向或密钥提取提供完整防护。

## 2. 当前加密机制

当前实现使用 Apple CryptoKit 的 `AES.GCM`，代码位置如下：

- 加密工具：`scripts/encrypt_art_assets.swift`
- 运行时加载器：`myPlayer2/Services/Theme/EncryptedArtAssetLoader.swift`

`AES.GCM` 是 AEAD 算法，密文带认证标签。运行时加载器会用认证标签验证密文完整性；如果 `.kmgasset` 被篡改、截断或使用了错误密钥，解密会失败，并由加载器记录主题日志后返回 `nil`，调用端再走 fallback。

`.kmgasset` 文件不是把 PNG 做 Base64、XOR 或简单改后缀。当前二进制结构如下：

| 字段 | 长度 | 说明 |
| --- | ---: | --- |
| magic | 8 bytes | 固定为 `KMGASSET`，用于识别文件格式 |
| version | 1 byte | 当前为 `1` |
| algorithm | 1 byte | 当前为 `1`，表示 `AES_GCM_256` |
| flags | 1 byte | 当前保留，写入 `0` |
| nonceLength | UInt16 big-endian | nonce 字节长度 |
| tagLength | UInt16 big-endian | GCM auth tag 字节长度 |
| ciphertextLength | UInt64 big-endian | 密文字节长度 |
| nonce | variable | AES-GCM nonce |
| ciphertext | variable | 图片原始数据的密文 |
| auth tag | variable | AES-GCM 认证标签 |

运行时加载器会校验 magic、version、algorithm 和长度字段。格式错误、版本不支持、算法不支持、认证失败、图片解码失败会被区分为不同错误类型。

密钥目前没有作为单一明文字符串写入源码。加密工具和运行时加载器都采用多段 `UInt8` 材料，运行时重组后结合固定上下文字符串做 `SHA256` 派生，得到 `SymmetricKey`。文档不记录真实密钥内容。

Debug 和 Release 差异：

- Debug 下 `EncryptedArtAssetLoader` 支持通过环境变量 `KMG_ART_ASSET_KEY_HEX` 使用 64 个十六进制字符形式的 256-bit 开发密钥。
- Debug 下 `BKThemeAssets` 默认允许从本地 `BKThemes/` 明文母版加载。设置 `KMG_USE_PLAIN_ART_ASSETS=0` 可强制走加密资源。
- Debug 下 `KMG_ART_ASSETS_PLAIN_ROOT` 可以指定本地明文 `BKThemes` 根目录。
- Release 下 `BKThemeAssets.usePlainArtAssetsInDebug` 为 `false`，不会依赖本地明文素材 fallback。

## 3. 目录结构与相关文件

本地明文母版素材目录：

- `BKThemes/Backgrounds/`
- `BKThemes/Mask/`
- `BKThemes/Shapes/`

加密输出目录：

- `EncryptedArtAssets/BKThemes/Backgrounds/`
- `EncryptedArtAssets/BKThemes/Mask/`
- `EncryptedArtAssets/BKThemes/Shapes/`

manifest：

- `EncryptedArtAssets/manifest.json`

加密工具：

- `scripts/encrypt_art_assets.swift`

运行时加载器：

- `myPlayer2/Services/Theme/EncryptedArtAssetLoader.swift`

统一调用端和主要使用位置：

- `myPlayer2/Views/NowPlaying/BKThemeAssets.swift`
  - 统一维护 BKThemes 的 logicalName、Debug 明文 fallback、加密加载、下采样和缓存。
- `myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift`
  - 使用 `BKThemeAssets.shared` 加载背景、形状和 mask 动画帧。
  - 背景、形状、mask 的布局、随机、颜色、视差和动画逻辑仍保留在原视图中。
- `myPlayer2/Views/Home/HomeAmbientShapesBackground.swift`
  - 使用 `BKThemeAssets.shared.shapes(maxPixel:)` 加载首页 ambient shapes。

构建配置：

- `kmgccc_player.xcodeproj/project.pbxproj`
  - `BKArt` target 的 Resources 阶段包含 `EncryptedArtAssets in Resources`。
  - `BKArt` target 不再复制 `BKThemes` 明文 PNG。
  - 主 App target 复制 `BKArt.bundle`。

## 4. 已加密素材清单

当前 `EncryptedArtAssets/manifest.json` 记录 31 个加密条目，算法为 `AES.GCM.256`，formatVersion 为 `1`。

| 分类 | 原始路径 | 加密后路径 | 数量 | 当前用途 | 调用端 | 状态 |
| --- | --- | --- | ---: | --- | --- | --- |
| Backgrounds | `BKThemes/Backgrounds/bk1.png`, `BKThemes/Backgrounds/bk2.png` | `EncryptedArtAssets/BKThemes/Backgrounds/bk1.kmgasset`, `EncryptedArtAssets/BKThemes/Backgrounds/bk2.kmgasset` | 2 | BKArt 背景图轮换 | `BKThemeAssets.backgrounds(maxPixel:)`, `BKThemeAssets.background(at:maxPixel:)`, `BKArtBackgroundView` | 已加密 |
| Mask | `BKThemes/Mask/frame_00.png` 到 `BKThemes/Mask/frame_17.png` | `EncryptedArtAssets/BKThemes/Mask/frame_00.kmgasset` 到 `EncryptedArtAssets/BKThemes/Mask/frame_17.kmgasset` | 18 | BKArt 转场 mask 动画帧 | `BKThemeAssets.maskFrames(maxPixel:)`, `BKThemeAssets.cachedMaskFrames(maxPixel:)`, `BKArtBackgroundView` | 已加密 |
| Shapes | `BKThemes/Shapes/shape1.png` 到 `BKThemes/Shapes/shape11.png` | `EncryptedArtAssets/BKThemes/Shapes/shape1.kmgasset` 到 `EncryptedArtAssets/BKThemes/Shapes/shape11.kmgasset` | 11 | BKArt 和 Home ambient shapes | `BKThemeAssets.shapes(maxPixel:)`, `BKArtBackgroundView`, `HomeAmbientShapesBackground` | 已加密 |

## 5. Assets.xcassets 审计状态

当前 `myPlayer2/Assets.xcassets` 下的图片集包括：

- `EmptyLyric`
- `cov1` 到 `cov4`
- `darkhole`
- `jntm`
- `kmglook`
- `lighthole`
- `seasons`
- `snowflake1` 到 `snowflake5`
- `tape`
- `tapedark`
- `tapegray`
- `tapemask`
- `tapeoutline`
- `tapepaper`

确认仍在使用的图片：

| 资源 | 引用位置 | 用途 |
| --- | --- | --- |
| `EmptyLyric` | `myPlayer2/Views/Lyrics/LyricsPanelView.swift`, `myPlayer2/Views/Settings/About/AboutSettingsView.swift` | 空歌词/关于页图像 |
| `jntm` | `myPlayer2/Views/Settings/About/AboutSettingsView.swift` | 关于页彩蛋图像 |
| `cov1` 到 `cov4` | `myPlayer2/Services/Library/PlaylistArtworkGenerator.swift` | 播放列表默认封面生成 |
| `kmglook` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 磁带皮肤图层 |
| `seasons` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 磁带皮肤图层 |
| `tape`, `tapedark` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 明暗磁带主体 |
| `tapegray` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 磁带皮肤灰色层 |
| `tapemask` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 磁带皮肤 mask |
| `tapeoutline` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 磁带皮肤描边 |
| `tapepaper` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 磁带皮肤纸面层 |
| `darkhole`, `lighthole` | `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` | 明暗主题孔洞图层 |

疑似未使用资源：

| 资源 | 状态 |
| --- | --- |
| `snowflake1` 到 `snowflake5` | 当前未在 Swift、SwiftUI、AppKit、HTML、CSS、plist 或运行时字符串审计中发现项目内引用，标记为 unused candidate |

本轮没有迁移任何 `Assets.xcassets` 图片。原因是本轮优先完成 `BKThemes` 的完整闭环：生成加密文件、替换实际调用链、调整 bundle 资源、验证 Release 资源包不含明文 PNG。`Assets.xcassets` 需要逐个确认引用、资产性质和迁移价值后再迁移。

不要在本轮删除 `snowflake1` 到 `snowflake5` 等疑似 unused 资源。删除 unused 资源必须单独处理，不能和素材加密迁移混在同一提交中。

`AccentColor` 是颜色资源，不属于图片加密范围。

## 6. 加密生成流程

### A. 开发时新增或修改原始素材

1. 修改本地 `BKThemes/Backgrounds/`、`BKThemes/Mask/` 或 `BKThemes/Shapes/` 下的 PNG 原始素材。
2. 运行加密脚本重新生成 `.kmgasset`。
3. 检查 `EncryptedArtAssets/manifest.json` 是否更新。
4. 提交 `.kmgasset`、`manifest.json`、加密脚本或调用端代码修改。
5. 不提交 `BKThemes/` 下的原始 PNG。

当前脚本是手动工具，未接入 Xcode Build Phase。推荐命令：

```sh
scripts/encrypt_art_assets.swift \
  --input BKThemes \
  --output EncryptedArtAssets \
  --logical-root BKThemes
```

强制重加密：

```sh
scripts/encrypt_art_assets.swift \
  --input BKThemes \
  --output EncryptedArtAssets \
  --logical-root BKThemes \
  --force
```

如果需要使用开发密钥覆盖默认嵌入密钥：

```sh
KMG_ART_ASSET_KEY_HEX=<64-hex-characters> \
scripts/encrypt_art_assets.swift \
  --input BKThemes \
  --output EncryptedArtAssets \
  --logical-root BKThemes
```

不要把真实密钥写入命令历史、仓库文件、Xcode build setting 或文档。

脚本当前行为：

- 只处理输入目录下的 `.png` 文件。
- 保持相对路径结构。
- 输出 `.kmgasset`，不把明文图片复制到 `EncryptedArtAssets/`。
- 读取已有 manifest；如果原图 sha256 未变化且加密文件存在，则跳过。
- 输出加密、跳过、失败数量和输出目录。

### B. 构建时

Release bundle 只应包含 `.kmgasset` 和 manifest，不应包含 `BKThemes` 明文 PNG。

当前没有自动加密 Build Phase。构建前需要手动运行 `scripts/encrypt_art_assets.swift`，并确保生成产物已提交或在本地存在。

Debug 下 `BKThemeAssets` 默认允许从本地明文 `BKThemes/` 加载，便于开发调试；Release 下该分支关闭。Debug 要模拟 Release 加密加载时，可设置：

```sh
KMG_USE_PLAIN_ART_ASSETS=0
```

### C. App 运行时

1. 调用端通过 `BKThemeAssets` 请求素材 logicalName，例如 `BKThemes/Shapes/shape1`。
2. `BKThemeAssets` 在 Release 下调用 `EncryptedArtAssetLoader`；Debug 下默认优先使用本地明文母版，或在 `KMG_USE_PLAIN_ART_ASSETS=0` 时走加密加载。
3. `EncryptedArtAssetLoader` 根据 logicalName 在 `EncryptedArtAssets/` 下定位 `.kmgasset`。
4. loader 读取文件并校验 header：magic、version、algorithm、长度字段。
5. loader 使用 `AES.GCM.open` 做认证解密。
6. loader 使用 ImageIO 从内存中的明文 `Data` 下采样解码为 `CGImage`。
7. loader 将 `CGImage` 写入 `NSCache`，缓存 key 包含 logicalName 和 maxPixel。
8. `BKThemeAssets` 继续维护背景、形状、mask 帧级缓存，并返回给 UI。
9. 失败时 loader 写入主题日志并返回 `nil`；调用端跳过该素材或保留原有 fallback，不崩溃。

## 7. App 运行时加载流程

运行时加载职责分为两层：

- `EncryptedArtAssetLoader` 只负责加密文件读取、格式校验、解密、图片解码和底层 `CGImage` 缓存。
- `BKThemeAssets` 负责业务素材枚举、Debug 明文路径、按场景下采样、BKArt/Home 共享缓存和 mask alpha 处理。

当前 logicalName 规则：

- `BKThemes/Backgrounds/bk1`
- `BKThemes/Backgrounds/bk2`
- `BKThemes/Mask/frame_00` 到 `BKThemes/Mask/frame_17`
- `BKThemes/Shapes/shape1` 到 `BKThemes/Shapes/shape11`

文件定位规则由 `EncryptedArtAssetLoader.encryptedURL(logicalName:in:)` 实现。例：

```text
BKThemes/Shapes/shape1
-> EncryptedArtAssets/BKThemes/Shapes/shape1.kmgasset
```

加载器搜索 bundle 顺序为：传入 bundle、`Bundle.main`、`Bundle(for: EncryptedArtAssetLoader.self)`，并去重。

## 8. Git 与本地素材管理

原始明文素材保留在本地 `BKThemes/`，但不提交 Git。当前 `.gitignore` 中使用根目录规则：

```gitignore
/BKThemes/
```

该规则只忽略项目根目录的本地母版素材，不忽略 `EncryptedArtAssets/BKThemes/` 下的加密产物。

检查是否有原始素材被 Git 追踪：

```sh
git ls-files | grep 'BKThemes'
```

如果发现原始素材已经被追踪，应只从索引移除，不删除本地文件：

```sh
git rm --cached <path>
```

需要提交的内容：

- `EncryptedArtAssets/**/*.kmgasset`
- `EncryptedArtAssets/manifest.json`
- `scripts/encrypt_art_assets.swift`
- `myPlayer2/Services/Theme/EncryptedArtAssetLoader.swift`
- `myPlayer2/Views/NowPlaying/BKThemeAssets.swift`
- `kmgccc_player.xcodeproj/project.pbxproj`
- 相关维护文档

不应提交的内容：

- `BKThemes/` 下的原始明文 PNG
- 真实密钥或本地密钥配置
- 临时解密产物
- DerivedData、构建中间目录和手动测试产生的临时文件

## 9. 发布前验证清单

发布前至少检查以下项目：

- `.app` 或 `BKArt.bundle` 内没有 `BKThemes/Backgrounds/*.png`。
- `.app` 或 `BKArt.bundle` 内没有 `BKThemes/Mask/*.png`。
- `.app` 或 `BKArt.bundle` 内没有 `BKThemes/Shapes/*.png`。
- `.app` 或 `BKArt.bundle` 内存在对应 `.kmgasset` 和 `EncryptedArtAssets/manifest.json`。
- 用 Finder、Preview 或 `file` 命令不能把 `.kmgasset` 直接当图片打开。
- App 中 BKArt 背景、mask 转场、shape 元素正常显示。
- Home ambient shapes 正常显示。
- mask 动画帧预热和缓存正常，不在播放每帧时反复解密造成卡顿。
- 临时移走一个 `.kmgasset` 时 App 不崩溃，并有主题日志。
- 修改 `.kmgasset` 若干字节后解密失败，App 不崩溃，并有认证失败或解密失败日志。
- 重复显示同一素材时命中缓存，不反复读取和解密。
- Release 模式不依赖本地 `BKThemes/` 明文素材。

可使用以下命令检查 `BKArt.bundle` 的资源内容：

```sh
xcodebuild \
  -project kmgccc_player.xcodeproj \
  -scheme BKArt \
  -configuration Release \
  -derivedDataPath .derivedDataAssetEncryption \
  CODE_SIGNING_ALLOWED=NO \
  build

bundle=".derivedDataAssetEncryption/Build/Products/Release/BKArt.bundle/Contents/Resources"

find "$bundle/EncryptedArtAssets" -name '*.kmgasset' | wc -l
test -f "$bundle/EncryptedArtAssets/manifest.json" && echo manifest-ok
find "$bundle" -type f \( \
  -path '*/BKThemes/*.png' \
  -o -name 'bk1.png' \
  -o -name 'bk2.png' \
  -o -name 'frame_*.png' \
  -o -name 'shape*.png' \
\)
```

最后一个 `find` 命令不应输出任何明文 BKThemes PNG。

## 10. 后续维护规范

### 新增 BKThemes 素材

1. 将原始 PNG 放入本地 `BKThemes/` 对应目录。
2. 如新增目录或命名规则超出当前范围，更新 `scripts/encrypt_art_assets.swift` 的输入策略或更新调用端枚举逻辑。
3. 运行加密脚本。
4. 在调用端使用新的 logicalName，例如 `BKThemes/Shapes/shape12`。
5. 检查 `EncryptedArtAssets/manifest.json` 新增条目。
6. 提交加密产物和代码修改，不提交原图。

### 替换现有素材

1. 保持 logicalName 不变。
2. 替换本地 `BKThemes/` 下的原始 PNG。
3. 重新运行加密脚本。
4. 检查 manifest 中对应条目的 `sha256Plaintext` 和 `sha256CipherFile` 已变化。
5. 回归测试显示效果，特别是背景切换、mask 动画和 shape 布局。

### 删除素材

1. 先确认没有调用引用。
2. 删除对应 `.kmgasset`。
3. 重新生成或手动更新 manifest，确保不保留失效条目。
4. 删除调用端 logicalName 或枚举引用。
5. 原始素材是否保留由本地素材管理决定，不要误删本地母版文件。

### 迁移 xcassets

1. 必须先做引用审计。
2. 只迁移确认仍在使用且属于原创艺术资产的图片。
3. 不迁移 `AccentColor`、系统图标、普通低价值 UI 资源或非图片资源。
4. 不能直接删除 `snowflake1` 到 `snowflake5` 等疑似 unused 资源；删除必须单独提交。
5. 迁移后应把调用端从 `Image("name")`、`NSImage(named:)` 等资源名加载改为统一的加密加载入口。

## 11. 常见问题排查

### 图片显示为空白怎么办

先检查 logicalName 是否存在对应加密文件。例如：

```text
BKThemes/Shapes/shape1
-> EncryptedArtAssets/BKThemes/Shapes/shape1.kmgasset
```

再检查 `BKThemeAssets` 是否枚举到了该资源，以及主题日志中是否有 `EncryptedArtAssetLoader` 的错误。

### 解密失败怎么办

解密失败通常来自密钥不一致、文件被篡改、文件截断或 header 异常。确认：

- 生成 `.kmgasset` 和运行 App 使用的是同一套密钥。
- 文件没有被手动编辑。
- manifest 中的 `sha256CipherFile` 与当前文件一致。
- Debug 环境变量 `KMG_ART_ASSET_KEY_HEX` 没有覆盖成错误值。

### manifest 找不到怎么办

运行时当前不依赖 manifest 定位文件；manifest 主要用于审计、增量生成和维护检查。若 manifest 缺失，重新运行加密脚本生成：

```sh
scripts/encrypt_art_assets.swift \
  --input BKThemes \
  --output EncryptedArtAssets \
  --logical-root BKThemes
```

发布前仍应确保 `EncryptedArtAssets/manifest.json` 被提交并复制进 bundle。

### Debug 能显示，Release 显示不了怎么办

Debug 默认可能走本地明文 `BKThemes/`，Release 不会。排查步骤：

1. 在 Debug 设置 `KMG_USE_PLAIN_ART_ASSETS=0`，模拟 Release 加密加载。
2. 检查 `EncryptedArtAssets/**/*.kmgasset` 是否存在。
3. 检查 `BKArt.bundle` 是否复制了 `EncryptedArtAssets`。
4. 检查 Release bundle 中是否错误缺失 `.kmgasset`。

### App bundle 里仍然出现 PNG 怎么办

检查 `kmgccc_player.xcodeproj/project.pbxproj` 中 `BKArt` target 的 Resources 阶段，确认没有 `BKThemes in Resources` 或文件系统同步规则把 `BKThemes` 自动复制进 bundle。

同时检查是否有新的资源目录、Build Phase 或 Copy Files 阶段把 `BKThemes` 复制进产物。

### 新增图片后 App 读取不到怎么办

确认三件事：

1. 原图已放在 `BKThemes/` 下。
2. 已重新运行加密脚本，`EncryptedArtAssets/manifest.json` 有新条目。
3. 调用端 logicalName 与生成路径一致，且 Xcode 复制了新的 `.kmgasset`。

### 性能变差怎么办

检查是否绕过了缓存，或是否在高频动画路径中不断改变 `maxPixel` 导致 cache key 变化。当前缓存层级包括：

- `EncryptedArtAssetLoader` 的 `NSCache<logicalName|maxPixel, CGImage>`。
- `BKThemeAssets` 的背景、shape、mask 帧缓存。

mask 帧应通过 `maskFrames(maxPixel:)` 预热或通过 `cachedMaskFrames(maxPixel:)` 复用，避免每帧动画时重新解密。

### 修改密钥后旧资源全部无法加载怎么办

这是预期行为。AES-GCM 认证要求生成和运行时使用同一密钥。修改密钥后，必须用新密钥重新生成所有 `.kmgasset`，并提交新的加密产物和 manifest。

## 12. 后续改进建议

- 将加密脚本接入可选 Build Phase，但必须保留增量逻辑，避免每次构建无意义重加密。
- 为 `EncryptedArtAssetLoader` 增加仅 Debug 启用的命中率或解密计数诊断，便于发布前确认缓存行为。
- 为 `.kmgasset` 增加独立校验工具，按 manifest 扫描缺失、篡改和过期文件。
- 分批迁移 `Assets.xcassets` 中确认仍在使用、确属原创艺术资产的图片。
- 为 Release 构建增加自动检查脚本，发现 `BKThemes` 明文 PNG 时直接失败。
