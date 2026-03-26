// PV Embed Core - TTML & LRC Parser
// 统一歌词解析，支持 LRC、TTML逐行、TTML逐字

import type { LyricLine, LyricChar, LyricFormat } from './types';

// ===== LRC Parser =====

const LRC_TIME_TAG_RE = /\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]/g;
const LRC_META_TAG_RE = /^\s*\[[a-zA-Z]+:.*\]\s*$/;

function parseLrcTimeToSeconds(minStr: string, secStr: string, fracStr?: string): number {
  const min = parseInt(minStr, 10);
  const sec = parseInt(secStr, 10);
  let frac = 0;
  
  if (fracStr) {
    if (fracStr.length === 1) frac = parseInt(fracStr, 10) / 10;
    else if (fracStr.length === 2) frac = parseInt(fracStr, 10) / 100;
    else frac = parseInt(fracStr.slice(0, 3), 10) / 1000;
  }
  
  return min * 60 + sec + frac;
}

export function parseLrc(content: string): LyricLine[] {
  const lines = content.replace(/^\uFEFF/, '').split(/\r?\n/);
  const result: LyricLine[] = [];
  
  for (const raw of lines) {
    const line = raw.trim();
    if (!line || LRC_META_TAG_RE.test(line)) continue;
    
    LRC_TIME_TAG_RE.lastIndex = 0;
    const times: number[] = [];
    
    let match: RegExpExecArray | null;
    while ((match = LRC_TIME_TAG_RE.exec(line)) !== null) {
      times.push(parseLrcTimeToSeconds(match[1], match[2], match[3]));
    }
    
    if (times.length === 0) continue;
    
    const text = line.replace(LRC_TIME_TAG_RE, '').trim();
    for (const time of times) {
      result.push({ 
        time, 
        text,
        endTime: time + 3 // LRC没有结束时间，默认3秒
      });
    }
  }
  
  result.sort((a, b) => a.time - b.time);
  
  // 计算endTime：取下一行的startTime，或当前+3秒
  for (let i = 0; i < result.length; i++) {
    if (i < result.length - 1) {
      result[i].endTime = result[i + 1].time;
    }
  }
  
  return result;
}

// ===== TTML Parser =====

export interface TTMLParseOptions {
  skipTranslation?: boolean;
  skipBackground?: boolean;
}

function parseTTMLTime(timeStr: string): number | null {
  if (!timeStr) return null;
  timeStr = String(timeStr).trim();
  
  // 匹配 hh:mm:ss.ms 或 mm:ss.ms
  const match = timeStr.match(/^(?:(\d+):)?(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?$/);
  if (match) {
    const hours = match[1] ? parseInt(match[1], 10) : 0;
    const mins = parseInt(match[2], 10);
    const secs = parseInt(match[3], 10);
    let ms = match[4] ? parseInt(match[4], 10) : 0;
    if (match[4] && match[4].length === 1) ms *= 100;
    else if (match[4] && match[4].length === 2) ms *= 10;
    return hours * 3600 + mins * 60 + secs + ms / 1000;
  }
  
  // 纯秒数
  const seconds = parseFloat(timeStr);
  return isNaN(seconds) ? null : seconds;
}

export function parseTTML(content: string, options: TTMLParseOptions = {}): LyricLine[] {
  const { skipTranslation = true, skipBackground = true } = options;
  const result: LyricLine[] = [];
  
  try {
    const parser = new DOMParser();
    const doc = parser.parseFromString(content, 'application/xml');
    
    if (doc.querySelector('parsererror')) {
      throw new Error('Invalid TTML XML');
    }
    
    // 获取所有 <p> 元素（歌词行）
    const paragraphs = doc.querySelectorAll('p');
    
    for (const p of paragraphs) {
      // 跳过翻译行
      if (skipTranslation && p.getAttribute('ttm:role') === 'translation') continue;
      
      const begin = parseTTMLTime(p.getAttribute('begin') || '');
      const end = parseTTMLTime(p.getAttribute('end') || '');
      if (begin === null) continue;
      
      // 获取所有直接子 span
      const spans = Array.from(p.querySelectorAll(':scope > span'));
      const chars: LyricChar[] = [];
      
      // 过滤背景行
      const mainSpans = skipBackground 
        ? spans.filter(s => s.getAttribute('ttm:role') !== 'x-bg')
        : spans;
      
      let lineText = '';
      let hasWordTiming = false;
      
      // 检查是否有逐字时间
      for (const span of mainSpans) {
        const wordBegin = parseTTMLTime(span.getAttribute('begin') || '');
        const wordEnd = parseTTMLTime(span.getAttribute('end') || '');
        const text = span.textContent || '';
        
        if (wordBegin !== null && text) {
          chars.push({
            text,
            time: wordBegin,
            endTime: wordEnd || wordBegin + 0.3,
            duration: wordEnd ? wordEnd - wordBegin : 0.3
          });
          hasWordTiming = true;
        } else if (text) {
          // 没有时间信息，累加到行文本
          lineText += text;
        }
      }
      
      // 构建行
      if (hasWordTiming && chars.length > 0) {
        // 逐字模式
        const fullText = chars.map(c => c.text).join('');
        const lastChar = chars[chars.length - 1];
        result.push({
          time: begin,
          endTime: end || lastChar.endTime,
          text: fullText,
          chars,
          hasChars: true
        });
      } else {
        // 逐行模式（从<p>标签提取文本）
        const pText = p.textContent?.trim() || '';
        if (pText) {
          result.push({
            time: begin,
            endTime: end || begin + 3,
            text: pText,
            hasChars: false
          });
        }
      }
    }
    
    // 按时间排序
    result.sort((a, b) => a.time - b.time);
    
  } catch (error) {
    console.error('[TTMLParser] Parse error:', error);
    throw error;
  }
  
  return result;
}

// ===== 统一解析入口 =====

export function detectLyricFormat(text: string): LyricFormat | null {
  const trimmed = text.trim();
  if (trimmed.startsWith('<?xml') || trimmed.startsWith('<tt')) {
    // 检查是否有逐字标记
    if (trimmed.includes('<span') && trimmed.includes('begin=')) {
      return 'ttml-word';
    }
    return 'ttml-line';
  }
  if (trimmed.includes('[') && /\[\d{1,2}:\d{2}/.test(trimmed)) {
    return 'lrc';
  }
  return null;
}

export function parseLyrics(text: string, format?: LyricFormat): { lines: LyricLine[]; format: LyricFormat } {
  const detectedFormat = format || detectLyricFormat(text) || 'lrc';
  
  let lines: LyricLine[];
  
  switch (detectedFormat) {
    case 'ttml-word':
    case 'ttml-line':
      lines = parseTTML(text);
      break;
    case 'lrc':
    default:
      lines = parseLrc(text);
      break;
  }
  
  return { lines, format: detectedFormat };
}

// ===== 歌词状态计算 =====

export function getCharState(char: LyricChar, currentTime: number): { state: 'future' | 'active' | 'done'; progress: number } {
  if (currentTime < char.time) {
    return { state: 'future', progress: 0 };
  }
  if (currentTime >= char.endTime) {
    return { state: 'done', progress: 1 };
  }
  const progress = (currentTime - char.time) / (char.endTime - char.time);
  return { state: 'active', progress };
}

export function getCurrentLine(lines: LyricLine[], currentTime: number): { line: LyricLine | null; index: number } {
  if (!lines || lines.length === 0) {
    return { line: null, index: -1 };
  }
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (currentTime >= line.time && currentTime < line.endTime) {
      return { line, index: i };
    }
  }
  
  // 检查是否在最后一行之后
  if (currentTime >= lines[lines.length - 1].endTime) {
    return { line: lines[lines.length - 1], index: lines.length - 1 };
  }
  
  // 在第一行之前
  return { line: null, index: -1 };
}

export function getCharStates(line: LyricLine, currentTime: number): Array<{ char: LyricChar; state: 'future' | 'active' | 'done'; progress: number }> | null {
  if (!line.chars || line.chars.length === 0) {
    return null;
  }
  
  return line.chars.map(char => ({
    char,
    ...getCharState(char, currentTime)
  }));
}
