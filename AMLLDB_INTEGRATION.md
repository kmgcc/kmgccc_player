# AMLLDB 集成说明

## 概述

AMLLDB (Apple Music-Like Lyrics Database) 已作为第4个歌词查找平台集成到 kmgccc_player。

## 新增文件

```
myPlayer2/
├── Models/
│   └── AMLLDBIndexEntry.swift      # SwiftData 模型存储索引条目
├── Services/
│   └── AMLLDB/
│       ├── AMLLDBClient.swift      # HTTP 客户端下载索引和歌词
│       ├── AMLLDBService.swift     # 索引管理和搜索服务
│       └── AMLLDBModels.swift      # 搜索相关数据模型
└── Services/
    └── LDDC/
        └── LDDCModels.swift        # 已更新，添加 AMLLDB 到 LDDCSource
```

## 修改文件

- `Views/Library/LDDCSearchSection.swift` - 集成 AMLLDB 搜索和下载

## 功能特性

### 1. 自动索引更新
- 启动 App 后，首次搜索歌词时自动检查更新
- 如果超过 24 小时未更新，自动下载新索引
- 索引文件存储在 SwiftData 中

### 2. 本地模糊搜索
- 支持按歌名和歌手搜索
- 匹配度排序：精确匹配 > 前缀匹配 > 包含匹配
- 最大返回 20 条结果

### 3. TTML 原生支持
- AMLLDB 直接提供 TTML 格式歌词
- 无需格式转换，可直接使用

### 4. 并行搜索
- LDDC 和 AMLLDB 搜索同时进行
- 结果合并并按匹配度排序

## 使用方法

1. 打开歌曲编辑页面
2. 在"LDDC 歌词搜索"部分，确保"AMLL 歌词库"已选中
3. 输入歌名和歌手，点击搜索
4. 首次使用会自动下载索引（约 10MB）
5. 选择 AMLLDB 结果，直接下载 TTML 歌词

## 技术细节

### 索引文件
- URL: `https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl`
- 大小: ~10MB
- 格式: JSON Lines

### TTML 歌词文件
- URL: `https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/ncm-lyrics/{ncmMusicId}.ttml`
- 格式: TTML (Timed Text Markup Language)

## 注意事项

- 首次使用需要下载索引文件，可能需要 30 秒左右
- 索引文件每天自动检查更新
- 搜索完全在本地进行，速度快
