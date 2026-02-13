# Changelog

本项目的所有主要更改都将记录在此通过此文件。

## [v1.0.3-beta] - 2026-02-14

### Changed
- **重要变更**: 默认音乐库路径已变更为 `~/Music/kmgccc_player Library`。若您是从旧版本升级，请手动将原 `~/Music/TrueMusic Library` 中的内容移动到新文件夹，以保留您的数据。


## [v1.0.2-beta2] - 2026-02-09

### Added
- 增加了彩蛋：在 About 界面使用“故人”的铁山靠动作即可触发。

## [v1.0.2-beta] - 2026-02-08



### Fixed
- 修复了影响播放列表管理与曲目排序的问题。
- 改善了在“正在播放”视图中切换曲目时的可靠性。
- 调整了部分 UI 元素，以在不同窗口尺寸下保持一致性。

### Changed
- 优化了磁带播放界面的视觉细节。
- 更新了文档，提供了更清晰的构建指引。
- 对 LDDC Server 进行了 Universal Build 打包，理论上支持 Apple Silicon 与 Intel 芯片，但目前尚未在 x86_64 平台上进行验证。

## [v1.0.1-beta] - 2026-02-07

### Added
- kmgccc_player 首个 Beta 版本。
- 引入适用于 macOS 26 的 Liquid Glass UI 设计。
- 支持 AMLL 歌词渲染。
- 添加基础本地库管理功能。

### Notes
- 这是一个早期预览版本。
- 包含已知问题及潜在的不稳定因素。
- 不建议在关键环境中作为日常主力播放器使用。
