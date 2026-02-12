#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
批量拆分LRC文件并转换为TTML，保留中间 split 文件和最终 TTML
"""

import re
import sys
from pathlib import Path

# 添加当前目录到 path
sys.path.insert(0, str(Path(__file__).parent))
from lrc_to_ttml_with_translation import convert_lrc_to_ttml_with_translation
from lrc_to_ttml import convert_lrc_to_ttml

ORI_DIR = Path(__file__).parent / 'test_convert' / 'ori'
SPLIT_DIR = Path(__file__).parent / 'test_convert' / 'split'
OUTPUT_DIR = Path(__file__).parent / 'test_convert' / 'output'


def has_chinese(text):
    """检查文本是否包含中文字符"""
    return bool(re.search(r'[\u4e00-\u9fff]', text))


def is_karaoke_line(line):
    """检查是否为卡拉OK格式（字级时间戳密集的行）"""
    timestamps = re.findall(r'\[\d+:\d+\.\d+\]', line)
    return len(timestamps) >= 4


def split_lrc(file_path):
    """将LRC文件拆分为原文和翻译两个文件"""
    with open(file_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    metadata_lines = []
    karaoke_lines = []
    other_lines = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # 跳过 problem 标记行
        if stripped.startswith('【') or stripped.startswith('[problem'):
            continue
        # 识别元数据行
        if any(tag in stripped for tag in ['[ti:', '[ar:', '[al:', '[by:', '[offset:', '[tool:']):
            metadata_lines.append(line)
            continue
        # 识别卡拉OK行（字级时间戳 >= 4 个）
        if is_karaoke_line(stripped):
            karaoke_lines.append(line)
        else:
            other_lines.append(line)

    ori_lines = []
    trans_lines = []
    has_separate_trans = False

    if karaoke_lines:
        ori_lines.extend(metadata_lines)
        ori_lines.extend(karaoke_lines)

        # 翻译行：包含中文的非卡拉OK行
        current_trans_lines = []
        for line in other_lines:
            if has_chinese(line):
                current_trans_lines.append(line)

        if current_trans_lines:
            trans_lines.extend(metadata_lines)
            trans_lines.extend(current_trans_lines)
            has_separate_trans = True
    else:
        # 无卡拉OK行，视为纯原文
        ori_lines.extend(metadata_lines)
        ori_lines.extend(other_lines)
        has_separate_trans = False

    SPLIT_DIR.mkdir(parents=True, exist_ok=True)

    ori_path = SPLIT_DIR / f"{file_path.stem}_ori.lrc"
    with open(ori_path, 'w', encoding='utf-8') as f:
        f.writelines(ori_lines)

    trans_path = None
    if has_separate_trans:
        trans_path = SPLIT_DIR / f"{file_path.stem}_trans.lrc"
        with open(trans_path, 'w', encoding='utf-8') as f:
            f.writelines(trans_lines)

    return ori_path, trans_path


def process_file(file_path):
    """处理单个LRC文件"""
    print(f"\n{'='*70}")
    print(f"处理: {file_path.name}")
    print(f"{'='*70}")

    try:
        ori_path, trans_path = split_lrc(file_path)
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
        output_ttml = OUTPUT_DIR / f"{file_path.stem}.ttml"

        if trans_path:
            print(f"  类型: 双语 (原文 + 翻译)")
            print(f"  原文: {ori_path}")
            print(f"  翻译: {trans_path}")
            convert_lrc_to_ttml_with_translation(str(ori_path), str(trans_path), str(output_ttml))
        else:
            print(f"  类型: 单语 (仅原文)")
            print(f"  原文: {ori_path}")
            convert_lrc_to_ttml(str(ori_path), str(output_ttml))

        size = output_ttml.stat().st_size
        print(f"  输出: {output_ttml}")
        print(f"  大小: {size} bytes")

        # 验证：检查翻译文本是否有残留时间戳
        if trans_path:
            with open(output_ttml, 'r', encoding='utf-8') as f:
                content = f.read()
            residual = re.findall(r'x-translation[^>]*>[^<]*\[\d+:\d+\.\d+\]', content)
            if residual:
                print(f"  ⚠️  发现 {len(residual)} 处翻译残留时间戳!")
                for r in residual[:3]:
                    print(f"     {r[-60:]}")
            else:
                print(f"  ✅ 翻译文本无残留时间戳")

        print(f"  ✅ 转换成功")

    except Exception as e:
        print(f"  ❌ 失败: {e}")
        import traceback
        traceback.print_exc()


def main():
    if not ORI_DIR.exists():
        print(f"错误：目录 {ORI_DIR} 不存在")
        sys.exit(1)

    lrc_files = sorted(ORI_DIR.glob('*.lrc'))
    print(f"找到 {len(lrc_files)} 个LRC文件\n")

    for f in lrc_files:
        process_file(f)

    print(f"\n{'='*70}")
    print("全部完成！")
    print(f"拆分文件保存在: {SPLIT_DIR}")
    print(f"TTML文件保存在: {OUTPUT_DIR}")
    print(f"{'='*70}")


if __name__ == '__main__':
    main()
