#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LRC到TTML格式转换工具（带翻译版）
支持字符级时间戳的精确转换，并将翻译附加到每句歌词下方
"""

import re
import xml.etree.ElementTree as ET
import argparse
from pathlib import Path
import sys


def parse_lrc_metadata(line):
    """解析LRC文件的元数据"""
    metadata = {}
    patterns = {
        'ti': 'title',
        'ar': 'artist', 
        'al': 'album',
        'by': 'creator',
        'offset': 'offset',
        'tool': 'tool'
    }
    
    for tag, key in patterns.items():
        pattern = rf'\[{tag}:([^\]]*)\]'
        match = re.search(pattern, line)
        if match:
            metadata[key] = match.group(1).strip()
    
    return metadata


def parse_time_to_seconds(time_str):
    """将时间字符串转换为秒数"""
    match = re.match(r'(\d+):(\d+)\.(\d+)', time_str)
    if match:
        minutes = int(match.group(1))
        seconds = int(match.group(2))
        milliseconds = int(match.group(3))
        return minutes * 60 + seconds + milliseconds / 1000
    return 0


def format_time_for_ttml(seconds):
    """将秒数转换为TTML时间格式"""
    if seconds < 0:
        seconds = 0
    minutes = int(seconds // 60)
    secs = seconds % 60
    return f"{minutes:02d}:{secs:06.3f}"


def is_song_info_line(text):
    """识别是否为歌曲信息行而非歌词内容"""
    if not text or not text.strip():
        return False
    
    text = text.strip()
    
    if text.startswith('*'):
        return True
    
    song_info_keywords = [
        '作词：', '作曲：', '编曲：', '制作：', '录音：', '混音：', 
        '发行：', '出品：', '母带：', '监制：', 'SP：', 'OP：',
        '作词:', '作曲:', '编曲:', '制作:', '录音:', '混音:', 
        '发行:', '出品:', '母带:', '监制:', 'SP:', 'OP:',
        'Lyrics:', 'Music:', 'Arrangement:', 'Producer:', 
        'Recording:', 'Mixing:', 'Mastering:','作词', '作曲', '编曲', '制作', '录音', '混音', '发行', '出品', '母带', '监制', 'SP', 'OP',
        'Lyrics', 'Music', 'Arrangement', 'Producer', 
        'Recording', 'Mixing', 'Mastering','和声','编写',"%","&","/","\\","-",
        'TME享有本翻译作品的著作权'  # 过滤版权声明
    ]
    
    for keyword in song_info_keywords:
        if keyword in text:
            return True
    
    colon_patterns = [
        r'^[^:：]*(?:作词|作曲|编曲|制作|录音|混音|发行|出品|母带|监制|SP|OP|词|曲|)[^:：]*[:：]',
        r'^[^:：]*(?:Lyrics|Music|Arrangement|Producer|Recording|Mixing|Mastering)[^:：]*[:：]',
        r'^[^:：]*(?:by|By|BY)[^:：]*[:：]',
        r'^[^:：]*(?:Studio|Label|Records)[^:：]*[:：]'
    ]
    
    for pattern in colon_patterns:
        if re.search(pattern, text, re.IGNORECASE):
            return True
    
    info_symbols = ['@', 'Studio', 'Records', 'Label', 'Copyright', '©']
    for symbol in info_symbols:
        if symbol in text:
            return True
    
    if text.isascii() and len(text) < 15 and any(keyword in text.lower() for keyword in ['studio', 'records', 'label', 'copyright']):
        return True
    
    return False


def filter_song_info_lines(lyrics_data):
    """批量过滤歌曲信息：找到最后一个info行，删除它及以上所有行"""
    if not lyrics_data:
        return lyrics_data
    
    last_info_index = -1
    
    for i, line_data in enumerate(lyrics_data):
        for segment in line_data['segments']:
            if is_song_info_line(segment['text']):
                last_info_index = i
                break
    
    if last_info_index >= 0:
        return lyrics_data[last_info_index + 1:]
    
    return lyrics_data


def parse_lrc_line_with_char_timing(line):
    """解析包含字符级时间戳的LRC行"""
    pattern = r'\[(\d+:\d+\.\d+)\]([^\[]*)'
    matches = re.findall(pattern, line)
    
    if not matches:
        return None
    
    segments = []
    for i, (time_str, text) in enumerate(matches):
        if text and text.strip():
            segment = {
                'time': parse_time_to_seconds(time_str),
                'text': text.strip()
            }
            
            if i + 1 < len(matches) and not matches[i + 1][1].strip():
                segment['next_line_start'] = parse_time_to_seconds(matches[i + 1][0])
            
            segments.append(segment)
    
    return segments


def parse_translation_lrc(lrc_file_path):
    """解析翻译LRC文件，返回 {start_time_seconds: translation_text} 的字典"""
    translations = {}
    
    try:
        with open(lrc_file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except UnicodeDecodeError:
        try:
            with open(lrc_file_path, 'r', encoding='gbk') as f:
                lines = f.readlines()
        except UnicodeDecodeError:
            with open(lrc_file_path, 'r', encoding='latin-1') as f:
                lines = f.readlines()
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        # 跳过元数据行
        if any(tag in line for tag in ['[ti:', '[ar:', '[al:', '[by:', '[offset:', '[tool:']):
            continue
        
        # 解析时间戳和文本
        match = re.match(r'\[(\d+:\d+\.\d+)\](.+)', line)
        if match:
            time_str = match.group(1)
            text = match.group(2).strip()
            
            # 过滤版权声明等信息行
            if is_song_info_line(text):
                continue
            
            start_time = parse_time_to_seconds(time_str)
            translations[start_time] = text
    
    return translations


def detect_lyric_type(lyrics_data):
    """检测歌词类型：逐字歌词 vs 逐行歌词"""
    if not lyrics_data:
        return "line"
    
    char_level_indicators = 0
    line_level_indicators = 0
    
    for line_data in lyrics_data:
        segments = line_data['segments']
        if len(segments) > 3:
            char_level_indicators += 1
        elif len(segments) == 1:
            line_level_indicators += 1
    
    if line_level_indicators > char_level_indicators:
        return "line"
    else:
        return "char"


def calculate_line_end_times(lyrics_data):
    """为逐行歌词计算正确的结束时间"""
    for i in range(len(lyrics_data)):
        line_data = lyrics_data[i]
        if not line_data['segments']:
            continue
            
        segment = line_data['segments'][0]
        
        if 'next_line_start' in segment:
            segment['end_time'] = segment['next_line_start']
        elif i + 1 < len(lyrics_data) and lyrics_data[i + 1]['segments']:
            next_start_time = lyrics_data[i + 1]['segments'][0]['time']
            segment['end_time'] = next_start_time
        else:
            text_len = len(segment['text'])
            duration = max(2.0, text_len * 0.3)
            segment['end_time'] = segment['time'] + duration
    
    return lyrics_data


def format_ttml_xml(xml_string):
    """生成紧凑的TTML XML"""
    compact_xml = xml_string.replace('\n', '').replace('\t', '').strip()
    return compact_xml


def calculate_segment_end_times(segments, default_duration=0.5):
    """计算每个片段的结束时间"""
    if not segments:
        return segments
    
    for i in range(len(segments)):
        if i + 1 < len(segments):
            segments[i]['end_time'] = segments[i + 1]['time']
        else:
            text_len = len(segments[i]['text'])
            duration = max(default_duration, text_len * 0.2)
            segments[i]['end_time'] = segments[i]['time'] + duration
    
    return segments


def find_translation_for_line(line_start_time, translations, tolerance=0.5):
    """根据行开始时间找到对应的翻译"""
    if not translations:
        return None
    
    # 精确匹配
    if line_start_time in translations:
        return translations[line_start_time]
    
    # 容差匹配
    for trans_time, trans_text in translations.items():
        if abs(trans_time - line_start_time) <= tolerance:
            return trans_text
    
    return None


def create_ttml_structure_with_translation(metadata, lyrics_data, translations):
    """创建带翻译的TTML XML结构"""
    ET.register_namespace('', 'http://www.w3.org/ns/ttml')
    ET.register_namespace('ttm', 'http://www.w3.org/ns/ttml#metadata')
    ET.register_namespace('amll', 'http://www.example.com/ns/amll')
    ET.register_namespace('itunes', 'http://music.apple.com/lyric-ttml-internal')
    
    root = ET.Element('tt')
    root.set('xmlns', 'http://www.w3.org/ns/ttml')
    root.set('xmlns:ttm', 'http://www.w3.org/ns/ttml#metadata')
    root.set('xmlns:amll', 'http://www.example.com/ns/amll')
    root.set('xmlns:itunes', 'http://music.apple.com/lyric-ttml-internal')
    
    head = ET.SubElement(root, 'head')
    metadata_elem = ET.SubElement(head, 'metadata')
    
    agent = ET.SubElement(metadata_elem, 'ttm:agent')
    agent.set('type', 'person')
    agent.set('xml:id', 'v1')
    
    body = ET.SubElement(root, 'body')
    
    if lyrics_data:
        all_segments = [segment for line_data in lyrics_data for segment in line_data['segments']]
        if all_segments:
            last_time = max(segment.get('end_time', segment['time']) for segment in all_segments)
            body.set('dur', format_time_for_ttml(last_time))
    
    div = ET.SubElement(body, 'div')
    if lyrics_data:
        all_segments = [segment for line_data in lyrics_data for segment in line_data['segments']]
        if all_segments:
            first_time = min(segment['time'] for segment in all_segments if segment['time'] > 0)
            last_time = max(segment.get('end_time', segment['time']) for segment in all_segments)
            div.set('begin', format_time_for_ttml(first_time))
            div.set('end', format_time_for_ttml(last_time))
    
    for i, line_data in enumerate(lyrics_data):
        if not line_data['segments']:
            continue
            
        p = ET.SubElement(div, 'p')
        
        line_start = line_data['segments'][0]['time']
        line_end = line_data['segments'][-1].get('end_time', line_data['segments'][-1]['time'] + 1.0)
        
        p.set('begin', format_time_for_ttml(line_start))
        p.set('end', format_time_for_ttml(line_end))
        p.set('ttm:agent', 'v1')
        p.set('itunes:key', f'L{i+1}')
        
        # 添加字符级span元素
        for j, segment in enumerate(line_data['segments']):
            span = ET.SubElement(p, 'span')
            
            text_content = segment['text']
            span.text = text_content
            span.set('begin', format_time_for_ttml(segment['time']))
            span.set('end', format_time_for_ttml(segment.get('end_time', segment['time'] + 0.5)))
            
            # 在英文单词之间添加空格
            if j < len(line_data['segments']) - 1:
                if text_content.isascii() and any(c.isalpha() for c in text_content):
                    next_segment = line_data['segments'][j + 1]
                    if next_segment['text'].isascii() and any(c.isalpha() for c in next_segment['text']):
                        span.tail = ' '
        
        # 查找并添加翻译
        translation = find_translation_for_line(line_start, translations)
        if translation:
            trans_span = ET.SubElement(p, 'span')
            trans_span.set('ttm:role', 'x-translation')
            trans_span.set('xml:lang', 'zh-CN')
            trans_span.text = translation
    
    return root


def convert_lrc_to_ttml_with_translation(orig_lrc_path, trans_lrc_path, output_file_path=None):
    """将原文LRC和翻译LRC文件转换为带翻译的TTML格式"""
    # 解析原文LRC
    try:
        with open(orig_lrc_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except UnicodeDecodeError:
        try:
            with open(orig_lrc_path, 'r', encoding='gbk') as f:
                lines = f.readlines()
        except UnicodeDecodeError:
            with open(orig_lrc_path, 'r', encoding='latin-1') as f:
                lines = f.readlines()
    
    metadata = {}
    lyrics_data = []
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        line_metadata = parse_lrc_metadata(line)
        metadata.update(line_metadata)
        
        if not any(tag in line for tag in ['[ti:', '[ar:', '[al:', '[by:', '[offset:', '[tool:']):
            segments = parse_lrc_line_with_char_timing(line)
            if segments:
                lyrics_data.append({'segments': segments})
    
    if not lyrics_data:
        raise ValueError("没有找到有效的歌词数据")
    
    # 过滤掉歌曲信息行
    lyrics_data = filter_song_info_lines(lyrics_data)
    
    # 解析翻译LRC
    translations = parse_translation_lrc(trans_lrc_path)
    
    # 检测歌词类型并计算合适的结束时间
    lyric_type = detect_lyric_type(lyrics_data)
    
    if lyric_type == "line":
        lyrics_data = calculate_line_end_times(lyrics_data)
    else:
        for line_data in lyrics_data:
            line_data['segments'] = calculate_segment_end_times(line_data['segments'])
    
    # 创建带翻译的TTML结构
    root = create_ttml_structure_with_translation(metadata, lyrics_data, translations)
    
    # 生成紧凑的XML格式
    rough_string = ET.tostring(root, encoding='unicode')
    formatted_xml = format_ttml_xml(rough_string)
    
    # 保存到文件
    if not output_file_path:
        input_path = Path(orig_lrc_path)
        # 移除 [Original] 后缀
        stem = input_path.stem
        if stem.endswith(' [Original]'):
            stem = stem[:-11]
        default_dir = input_path.parent / 'covered'
        default_dir.mkdir(parents=True, exist_ok=True)
        output_file_path = default_dir / f"{stem}.ttml"
    
    with open(output_file_path, 'w', encoding='utf-8') as f:
        f.write(formatted_xml)
    
    return output_file_path


def main():
    """主函数 - 命令行交互"""
    print("LRC到TTML转换工具（带翻译版）")
    print("==============================")
    print("支持字符级时间戳的精确转换，含翻译")
    print()
    
    parser = argparse.ArgumentParser(
        description='将LRC歌词文件（原文+翻译）转换为带翻译的TTML格式',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:
  python3 lrc_to_ttml_with_translation.py                                    # 交互式输入
  python3 lrc_to_ttml_with_translation.py -i orig.lrc -t trans.lrc           # 指定输入
  python3 lrc_to_ttml_with_translation.py -i orig.lrc -t trans.lrc -o out.ttml
        """
    )
    parser.add_argument('--input', '-i', help='输入的原文LRC文件路径')
    parser.add_argument('--translation', '-t', help='输入的翻译LRC文件路径')
    parser.add_argument('--output', '-o', help='输出的TTML文件路径（可选）')
    parser.add_argument('--version', action='version', version='LRC to TTML (with Translation) Converter 1.0')
    
    args = parser.parse_args()
    
    # 获取输入文件路径
    if args.input:
        orig_lrc_file = args.input
    else:
        orig_lrc_file = input("请输入原文LRC文件路径: ").strip().strip('"\'')
    
    if args.translation:
        trans_lrc_file = args.translation
    else:
        trans_lrc_file = input("请输入翻译LRC文件路径: ").strip().strip('"\'')
    
    # 检查文件是否存在
    if not Path(orig_lrc_file).exists():
        print(f"❌ 错误：原文文件 '{orig_lrc_file}' 不存在")
        sys.exit(1)
    
    if not Path(trans_lrc_file).exists():
        print(f"❌ 错误：翻译文件 '{trans_lrc_file}' 不存在")
        sys.exit(1)
    
    try:
        print("🔄 正在转换...")
        output_file = convert_lrc_to_ttml_with_translation(orig_lrc_file, trans_lrc_file, args.output)
        print("✅ 转换成功！")
        print(f"📁 原文文件: {orig_lrc_file}")
        print(f"📁 翻译文件: {trans_lrc_file}")
        print(f"📁 输出文件: {output_file}")
        
        output_size = Path(output_file).stat().st_size
        print(f"📊 输出文件大小: {output_size} bytes")
        
    except Exception as e:
        print(f"❌ 转换失败：{e}")
        if args.input:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
