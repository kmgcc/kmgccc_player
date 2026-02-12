#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LRC到TTML格式转换工具
支持字符级时间戳的精确转换
"""
# output_file_path = 'lyrics/covered'

import re
import xml.etree.ElementTree as ET
from xml.dom import minidom
import argparse
from pathlib import Path
import sys


def parse_lrc_metadata(line):
    """解析LRC文件的元数据"""
    metadata = {}
    # 匹配标准LRC标签 [tag:value]
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
    # 格式: mm:ss.xxx
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
    
    # 过滤以*开头的注释行
    if text.startswith('*'):
        return True
    
    # 包含特定歌曲信息关键词的行
    song_info_keywords = [
        '作词：', '作曲：', '编曲：', '制作：', '录音：', '混音：', 
        '发行：', '出品：', '母带：', '监制：', 'SP：', 'OP：',
        '作词:', '作曲:', '编曲:', '制作:', '录音:', '混音:', 
        '发行:', '出品:', '母带:', '监制:', 'SP:', 'OP:',
        'Lyrics:', 'Music:', 'Arrangement:', 'Producer:', 
        'Recording:', 'Mixing:', 'Mastering:','作词', '作曲', '编曲', '制作', '录音', '混音', '发行', '出品', '母带', '监制', 'SP', 'OP',
        'Lyrics', 'Music', 'Arrangement', 'Producer', 
        'Recording', 'Mixing', 'Mastering','和声','编写',"%","&","/","\\","-"
    ]
    
    # 检查是否包含歌曲信息关键词
    for keyword in song_info_keywords:
        if keyword in text:
            return True
    
    # 检查明确的制作信息模式（更精确的冒号判断）
    # 只有当冒号前面是明确的制作信息词汇时才过滤
    colon_patterns = [
        r'^[^:：]*(?:作词|作曲|编曲|制作|录音|混音|发行|出品|母带|监制|SP|OP|词|曲|)[^:：]*[:：]',
        r'^[^:：]*(?:Lyrics|Music|Arrangement|Producer|Recording|Mixing|Mastering)[^:：]*[:：]',
        r'^[^:：]*(?:by|By|BY)[^:：]*[:：]',  # 制作人信息
        r'^[^:：]*(?:Studio|Label|Records)[^:：]*[:：]'  # 工作室信息
    ]
    
    for pattern in colon_patterns:
        if re.search(pattern, text, re.IGNORECASE):
            return True
    
    # 检查特定的制作信息符号（但排除在歌词中常见的）
    # 移除括号，因为英文歌词中很常见
    info_symbols = ['@', 'Studio', 'Records', 'Label', 'Copyright', '©']
    for symbol in info_symbols:
        if symbol in text:
            return True
    
    # 移除对纯英文的过滤，因为英文歌词本身就是英文
    # 只检查是否为明显的制作信息格式
    if text.isascii() and len(text) < 15 and any(keyword in text.lower() for keyword in ['studio', 'records', 'label', 'copyright']):
        return True
    
    return False


def filter_song_info_lines(lyrics_data):
    """批量过滤歌曲信息：找到最后一个info行，删除它及以上所有行"""
    if not lyrics_data:
        return lyrics_data
    
    last_info_index = -1
    
    # 找到最后一个包含歌曲信息的行
    for i, line_data in enumerate(lyrics_data):
        for segment in line_data['segments']:
            if is_song_info_line(segment['text']):
                last_info_index = i
                break  # 找到这一行有info就跳出内层循环
    
    # 如果找到info行，删除该行及之前的所有行
    if last_info_index >= 0:
        return lyrics_data[last_info_index + 1:]
    
    return lyrics_data


def parse_lrc_line_with_char_timing(line):
    """解析包含字符级时间戳的LRC行，支持逐行和逐字两种格式"""
    # 提取所有时间戳和对应的文字
    pattern = r'\[(\d+:\d+\.\d+)\]([^\[]*)'
    matches = re.findall(pattern, line)
    
    if not matches:
        return None
    
    segments = []
    for i, (time_str, text) in enumerate(matches):
        # 只过滤掉纯空格，保留其他字符（包括标点符号）
        if text and text.strip():
            segment = {
                'time': parse_time_to_seconds(time_str),
                'text': text.strip()
            }
            
            # 检查是否为逐行歌词格式（下一个时间戳没有文字，表示是结束时间）
            if i + 1 < len(matches) and not matches[i + 1][1].strip():
                segment['next_line_start'] = parse_time_to_seconds(matches[i + 1][0])
            
            segments.append(segment)
    
    return segments


def detect_lyric_type(lyrics_data):
    """检测歌词类型：逐字歌词 vs 逐行歌词"""
    if not lyrics_data:
        return "line"
    
    # 检查是否有多字符行，且每行segment数量较少
    char_level_indicators = 0
    line_level_indicators = 0
    
    for line_data in lyrics_data:
        segments = line_data['segments']
        if len(segments) > 3:  # 如果一行有超过3个段落，可能是字符级
            char_level_indicators += 1
        elif len(segments) == 1:  # 如果一行只有一个段落，可能是行级
            line_level_indicators += 1
    
    # 如果大部分行都是单段落，认为是逐行歌词
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
            
        # 对于逐行歌词，每行只有一个segment
        segment = line_data['segments'][0]
        
        # 优先使用解析时发现的下一行开始时间
        if 'next_line_start' in segment:
            segment['end_time'] = segment['next_line_start']
        # 如果没有，尝试使用下一行的开始时间
        elif i + 1 < len(lyrics_data) and lyrics_data[i + 1]['segments']:
            next_start_time = lyrics_data[i + 1]['segments'][0]['time']
            segment['end_time'] = next_start_time
        else:
            # 最后一行，使用默认的持续时间
            text_len = len(segment['text'])
            duration = max(2.0, text_len * 0.3)  # 最少2秒，每字0.3秒
            segment['end_time'] = segment['time'] + duration
    
    return lyrics_data


def format_ttml_xml(xml_string):
    """生成紧凑的TTML XML，同时保留单词间的必要空格"""
    # 移除由 tostring 引入的换行符和制表符。
    # 关键是，我们不再使用 re.sub(r'>\s+<', '><', ...) 
    # 因为它会错误地移除由 .tail 属性在 <span> 标签之间创建的空格。
    compact_xml = xml_string.replace('\n', '').replace('\t', '').strip()
    return compact_xml


def calculate_segment_end_times(segments, default_duration=0.5):
    """计算每个片段的结束时间"""
    if not segments:
        return segments
    
    # 为每个片段计算结束时间
    for i in range(len(segments)):
        if i + 1 < len(segments):
            # 下一个片段的开始时间就是当前片段的结束时间
            segments[i]['end_time'] = segments[i + 1]['time']
        else:
            # 最后一个片段，根据文字长度估算持续时间
            text_len = len(segments[i]['text'])
            duration = max(default_duration, text_len * 0.2)  # 每个字符0.2秒
            segments[i]['end_time'] = segments[i]['time'] + duration
    
    return segments


def create_ttml_structure(metadata, lyrics_data):
    """创建TTML XML结构"""
    # 创建根元素并设置命名空间
    ET.register_namespace('', 'http://www.w3.org/ns/ttml')
    ET.register_namespace('ttm', 'http://www.w3.org/ns/ttml#metadata')
    ET.register_namespace('amll', 'http://www.example.com/ns/amll')
    ET.register_namespace('itunes', 'http://music.apple.com/lyric-ttml-internal')
    
    root = ET.Element('tt')
    root.set('xmlns', 'http://www.w3.org/ns/ttml')
    root.set('xmlns:ttm', 'http://www.w3.org/ns/ttml#metadata')
    root.set('xmlns:amll', 'http://www.example.com/ns/amll')
    root.set('xmlns:itunes', 'http://music.apple.com/lyric-ttml-internal')
    
    # 创建head部分
    head = ET.SubElement(root, 'head')
    metadata_elem = ET.SubElement(head, 'metadata')
    
    # 添加代理人信息
    agent = ET.SubElement(metadata_elem, 'ttm:agent')
    agent.set('type', 'person')
    agent.set('xml:id', 'v1')
    
    # 如果有多个说话者，添加第二个代理人
    agent2 = ET.SubElement(metadata_elem, 'ttm:agent')
    agent2.set('type', 'other')
    agent2.set('xml:id', 'v2')
    
    # 创建body部分
    body = ET.SubElement(root, 'body')
    
    # 计算总时长
    if lyrics_data:
        all_segments = [segment for line_data in lyrics_data for segment in line_data['segments']]
        if all_segments:
            last_time = max(segment.get('end_time', segment['time']) for segment in all_segments)
            body.set('dur', format_time_for_ttml(last_time))
    
    # 创建div容器
    div = ET.SubElement(body, 'div')
    if lyrics_data:
        all_segments = [segment for line_data in lyrics_data for segment in line_data['segments']]
        if all_segments:
            first_time = min(segment['time'] for segment in all_segments if segment['time'] > 0)
            last_time = max(segment.get('end_time', segment['time']) for segment in all_segments)
            div.set('begin', format_time_for_ttml(first_time))
            div.set('end', format_time_for_ttml(last_time))
    
    # 添加歌词段落
    for i, line_data in enumerate(lyrics_data):
        if not line_data['segments']:
            continue
            
        # 创建段落元素
        p = ET.SubElement(div, 'p')
        p.set('ttm:agent', 'v1')
        p.set('itunes:key', f'L{i+1}')
        
        # 设置段落的开始和结束时间
        line_start = line_data['segments'][0]['time']
        line_end = line_data['segments'][-1].get('end_time', line_data['segments'][-1]['time'] + 1.0)
        p.set('begin', format_time_for_ttml(line_start))
        p.set('end', format_time_for_ttml(line_end))
        
        # 添加字符级span元素
        for j, segment in enumerate(line_data['segments']):
            span = ET.SubElement(p, 'span')
            
            # 单词保持纯净，不包含尾随空格
            text_content = segment['text']
            span.text = text_content
            span.set('begin', format_time_for_ttml(segment['time']))
            span.set('end', format_time_for_ttml(segment.get('end_time', segment['time'] + 0.5)))
            
            # 在单词之间添加空格，句尾不加
            # 使用 .tail 属性将空格放在 </span> 标签之后
            if j < len(line_data['segments']) - 1:
                # 检查当前和下一个 segment 是否都是英文单词，以决定是否添加空格
                if text_content.isascii() and any(c.isalpha() for c in text_content):
                    next_segment = line_data['segments'][j + 1]
                    if next_segment['text'].isascii() and any(c.isalpha() for c in next_segment['text']):
                        span.tail = ' '
    
    return root


def convert_lrc_to_ttml(lrc_file_path, output_file_path=None, strip_metadata=True):
    """将LRC文件转换为TTML格式"""
    try:
        with open(lrc_file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except UnicodeDecodeError:
        # 尝试其他编码
        try:
            with open(lrc_file_path, 'r', encoding='gbk') as f:
                lines = f.readlines()
        except UnicodeDecodeError:
            with open(lrc_file_path, 'r', encoding='latin-1') as f:
                lines = f.readlines()
    
    metadata = {}
    lyrics_data = []
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        # 解析元数据
        line_metadata = parse_lrc_metadata(line)
        metadata.update(line_metadata)
        
        # 解析歌词行（跳过纯元数据行）
        if not any(tag in line for tag in ['[ti:', '[ar:', '[al:', '[by:', '[offset:', '[tool:']):
            segments = parse_lrc_line_with_char_timing(line)
            if segments:
                lyrics_data.append({'segments': segments})
    
    if not lyrics_data:
        raise ValueError("没有找到有效的歌词数据")
    
    # 可选：过滤掉歌曲信息行
    if strip_metadata:
        lyrics_data = filter_song_info_lines(lyrics_data)

    # 检测歌词类型并计算合适的结束时间
    lyric_type = detect_lyric_type(lyrics_data)
    
    if lyric_type == "line":
        # 逐行歌词：使用下一行开始时间作为结束时间
        lyrics_data = calculate_line_end_times(lyrics_data)
    else:
        # 逐字歌词：使用字符级时间计算
        for line_data in lyrics_data:
            line_data['segments'] = calculate_segment_end_times(line_data['segments'])
    
    # 创建TTML结构
    root = create_ttml_structure(metadata, lyrics_data)
    
    # 生成紧凑的XML格式，避免span标签间的空格
    rough_string = ET.tostring(root, encoding='unicode')
    
    # 手动格式化XML，确保span标签在同一行
    formatted_xml = format_ttml_xml(rough_string)
    
    # 保存到文件
    if not output_file_path:
        input_path = Path(lrc_file_path)
        default_dir = input_path.parent / 'covered'
        default_dir.mkdir(parents=True, exist_ok=True)
        output_file_path = default_dir / input_path.with_suffix('.ttml').name
    
    with open(output_file_path, 'w', encoding='utf-8') as f:
        f.write(formatted_xml)
    
    return output_file_path


def main():
    """主函数 - 命令行交互"""
    print("LRC到TTML转换工具")
    print("==================")
    print("支持字符级时间戳的精确转换")
    print()
    
    # 命令行参数解析
    parser = argparse.ArgumentParser(
        description='将LRC歌词文件转换为TTML格式',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:
  python3 lrc_to_ttml.py                          # 交互式输入文件路径
  python3 lrc_to_ttml.py -i song.lrc               # 指定输入文件
  python3 lrc_to_ttml.py -i song.lrc -o output.ttml # 指定输入输出文件
        """
    )
    parser.add_argument('--input', '-i', help='输入的LRC文件路径')
    parser.add_argument('--output', '-o', help='输出的TTML文件路径（可选）')
    parser.add_argument(
        '--strip-metadata',
        dest='strip_metadata',
        action='store_true',
        default=True,
        help='转换时去除疑似平台声明/制作信息行（默认开启）'
    )
    parser.add_argument(
        '--no-strip-metadata',
        dest='strip_metadata',
        action='store_false',
        help='仅做LRC到TTML格式转换，不移除任何歌词行'
    )
    parser.add_argument('--version', action='version', version='LRC to TTML Converter 1.0')
    
    args = parser.parse_args()
    
    # 获取输入文件路径
    if args.input:
        lrc_file = args.input
    else:
        lrc_file = input("请输入LRC文件路径: ").strip().strip('"\'')
    
    # 检查文件是否存在
    if not Path(lrc_file).exists():
        print(f"❌ 错误：文件 '{lrc_file}' 不存在")
        sys.exit(1)
    
    if not lrc_file.lower().endswith('.lrc'):
        print("⚠️  警告：输入文件可能不是LRC格式")
    
    try:
        # 执行转换
        print("🔄 正在转换...")
        output_file = convert_lrc_to_ttml(
            lrc_file,
            args.output,
            strip_metadata=args.strip_metadata
        )
        print("✅ 转换成功！")
        print(f"📁 输入文件: {lrc_file}")
        print(f"📁 输出文件: {output_file}")
        
        # 显示文件信息
        input_size = Path(lrc_file).stat().st_size
        output_size = Path(output_file).stat().st_size
        print(f"📊 文件大小: {input_size} bytes → {output_size} bytes")
        
    except Exception as e:
        print(f"❌ 转换失败：{e}")
        if args.input:  # 命令行模式下显示详细错误
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main() 
