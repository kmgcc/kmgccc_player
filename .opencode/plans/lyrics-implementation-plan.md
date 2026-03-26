# Word-by-Word Lyrics Animation & TTML Parsing Implementation Plan

## Executive Summary

This plan implements word-by-word lyrics animation with unified LRC/TTML parsing support for the PV demo's lyrics component. The implementation follows TDD principles with atomic commits and supports parallel execution.

---

## Current State Analysis

### Existing System
- **LRC Parser**: Function `Wi` at `pv-demo/assets/index-BTWadPDx.js:1-50`
  - Supports `[mm:ss.xx]` format
  - Returns `{time, text}` array
  - Time unit: **seconds (float)**
- **Data Structure**: `lyricTimeline` = array of `{time, text}`, `lyricCursor` for index
- **Display**: `getDisplayText(time)` uses cursor-based O(1) lookup
- **Effects**: heroText, glowTextCards, etc. (28 templates, 70+ effects)

### Key Findings
- Cursor-based lookup is efficient - don't change this
- Time is stored as **seconds (float)** internally
- Effects use PixiJS with custom shaders
- Current system is line-level only

---

## Implementation Overview

### Phase 1: Data Model & Parsers (Foundation)
### Phase 2: Unified Entry Point (Integration)
### Phase 3: Word-Level Animation (Rendering)
### Phase 4: Testing & Validation (Quality)

---

## Detailed Task Breakdown

### PHASE 1: UNIFIED LYRICS DATA MODEL

**Task 1.1: Enhanced Lyric Line Data Structure**
- **File**: `pv-demo/src/lyrics/types.ts` (NEW)
- **Dependencies**: None
- **TDD**: Write tests first defining the interface

```typescript
// Unified lyrics data model
interface LyricChar {
  time: number;      // Start time in seconds
  text: string;      // Character/word text
  duration?: number; // Optional: calculated or explicit end time
}

interface LyricLine {
  time: number;      // Line start time in seconds
  text: string;      // Full line text
  endTime?: number;  // Line end time (calculated or explicit)
  chars?: LyricChar[]; // Optional: word/char-level timing
}

// Backward-compatible: lines without chars work normally
type LyricTimeline = LyricLine[];
```

**Task 1.2: Enhanced LRC Parser**
- **File**: `pv-demo/src/parsers/lrc.ts` (NEW)
- **Dependencies**: Task 1.1
- **TDD**: Test with sample LRC files

**Requirements:**
1. Support standard line-level LRC `[mm:ss.xx]`
2. Support Enhanced LRC with word-level tags: `[mm:ss.xx]<mm:ss.xx>word<mm:ss.xx>`
3. Auto-derive end times using next word's start time
4. Return unified `LyricLine[]` format

**Parsing Strategy:**
```javascript
// Enhanced LRC regex patterns
const LINE_TIME_REGEX = /\[(\d{1,2}):(\d{2})[.:](\d{1,3})\]/g;
const WORD_TIME_REGEX = /<(\d{1,2}):(\d{2})[.:](\d{1,3})>([^<]*)/g;

function parseEnhancedLRC(lrcText) {
  const lines = lrcText.replace(/^\uFEFF/, "").split(/\r?\n/);
  const result = [];
  
  for (const line of lines) {
    // Parse line-level timestamp
    // If word-level tags exist, parse them into chars[]
    // Calculate end times for each word
    // Push unified LyricLine object
  }
  
  return result;
}
```

**Task 1.3: TTML Parser**
- **File**: `pv-demo/src/parsers/ttml.ts` (NEW)
- **Dependencies**: Task 1.1
- **TDD**: Test with sample TTML file from `pv-demo/lyrics.ttml`

**Requirements:**
1. Parse `<p begin="..." end="...">` as lines
2. Parse `<span begin="..." end="...">` as chars within lines
3. Support time formats: `HH:MM:SS.mmm`, `MM:SS.mmm`, `seconds`
4. Filter: ignore translation lines, bg lines (keep main lyrics only)
5. Explicit errors on parse failure

**Parsing Strategy:**
```typescript
function parseTTML(ttmlText: string): LyricLine[] {
  const domParser = new DOMParser();
  const doc = domParser.parseFromString(ttmlText, "application/xml");
  
  // Validate XML
  const parserError = doc.querySelector("parsererror");
  if (parserError) throw new Error(`TTML parse error: ${parserError.textContent}`);
  
  const lines: LyricLine[] = [];
  
  for (const p of doc.querySelectorAll("p[begin][end]")) {
    const line: LyricLine = {
      time: parseTime(p.getAttribute("begin")!),
      text: "",
      endTime: parseTime(p.getAttribute("end")!),
      chars: []
    };
    
    // Parse spans within line
    for (const span of p.querySelectorAll("span[begin][end]")) {
      const char: LyricChar = {
        time: parseTime(span.getAttribute("begin")!),
        text: span.textContent || "",
        duration: parseTime(span.getAttribute("end")!) - parseTime(span.getAttribute("begin")!)
      };
      line.chars.push(char);
      line.text += char.text;
    }
    
    // Filter: skip if marked as translation or bg
    if (!isTranslationLine(p) && !isBackgroundLine(p)) {
      lines.push(line);
    }
  }
  
  return lines;
}

function parseTime(timeStr: string): number {
  // Handle "1:08.183" → 68.183 seconds
  // Handle "00:01:08.183" → 68.183 seconds
  // Handle "68.183s" → 68.183 seconds
}
```

**Task 1.4: Format Detection Utility**
- **File**: `pv-demo/src/parsers/detect.ts` (NEW)
- **Dependencies**: None
- **TDD**: Test detection on sample files

```typescript
function detectLyricsFormat(text: string): 'lrc' | 'ttml' | 'unknown' {
  // Check for XML/TTML markers
  if (text.trim().startsWith('<?xml') || text.includes('<tt ')) {
    return 'ttml';
  }
  // Check for LRC time tags
  if (/\[\d{1,2}:\d{2}[.:]\d{1,3}\]/.test(text)) {
    return 'lrc';
  }
  return 'unknown';
}
```

**Atomic Commit 1**: `feat(lyrics): unified data model and parsers`
- Includes: types.ts, lrc.ts, ttml.ts, detect.ts
- Includes: comprehensive unit tests
- Verified: all parsers pass tests

---

### PHASE 2: UNIFIED ENTRY POINT

**Task 2.1: Extend setLyricTimeline()**
- **File**: `pv-demo/src/engine/PVEngine.ts` (MODIFY)
- **Dependencies**: Phase 1 complete
- **TDD**: Test with both LRC and TTML inputs

**Current Implementation:**
```javascript
setLyricTimeline(parsedLRC) {
  // parsedLRC is result from Wi() function
  this.lyricTimeline = parsedLRC; // Array of {time, text}
  this.lyricCursor = 0;
}
```

**Enhanced Implementation:**
```typescript
setLyricTimeline(lyricsText: string) {
  const format = detectLyricsFormat(lyricsText);
  
  let parsed: LyricLine[];
  switch (format) {
    case 'ttml':
      parsed = parseTTML(lyricsText);
      break;
    case 'lrc':
      parsed = parseEnhancedLRC(lyricsText);
      break;
    default:
      throw new Error(`Unknown lyrics format: ${lyricsText.slice(0, 100)}...`);
  }
  
  // Validate and sort
  this.lyricTimeline = this.validateAndSortLyrics(parsed);
  this.lyricCursor = 0;
  this.currentLine = null;
  this.currentCharIndex = 0;
}

private validateAndSortLyrics(lines: LyricLine[]): LyricLine[] {
  // Remove invalid lines
  // Sort by time
  // Calculate end times if missing
  return lines
    .filter(line => line.time >= 0 && line.text)
    .sort((a, b) => a.time - b.time);
}
```

**Task 2.2: Update getDisplayText() for Word-Level**
- **File**: `pv-demo/src/engine/PVEngine.ts` (MODIFY)
- **Dependencies**: Task 2.1
- **TDD**: Test cursor movement with word-level data

**Enhanced Implementation:**
```typescript
getDisplayText(time: number): { text: string; chars?: LyricChar[]; charIndex?: number } {
  const t = Math.max(0, time + this.lyricOffsetSeconds);
  
  // Reset cursor if seeking backwards
  if (t < this.lastLyricTime) {
    this.lyricCursor = 0;
    this.currentCharIndex = 0;
  }
  this.lastLyricTime = t;
  
  // Find current line (cursor-based for performance)
  while (this.lyricCursor + 1 < this.lyricTimeline.length &&
         this.lyricTimeline[this.lyricCursor + 1].time <= t) {
    this.lyricCursor++;
    this.currentCharIndex = 0; // Reset char index on line change
  }
  
  const line = this.lyricTimeline[this.lyricCursor];
  if (!line || t < line.time) {
    return { text: this.userText || "" };
  }
  
  // If line has word-level timing, find current word
  if (line.chars && line.chars.length > 0) {
    // Find current char index within line
    while (this.currentCharIndex + 1 < line.chars.length &&
           line.chars[this.currentCharIndex + 1].time <= t) {
      this.currentCharIndex++;
    }
    
    return {
      text: line.text,
      chars: line.chars,
      charIndex: this.currentCharIndex
    };
  }
  
  // Line-level only
  return { text: line.text };
}
```

**Atomic Commit 2**: `feat(lyrics): unified entry point with format auto-detection`
- Includes: PVEngine.ts modifications
- Includes: backward compatibility verified
- Verified: both LRC and TTML work correctly

---

### PHASE 3: WORD-LEVEL ANIMATION RENDERING

**Task 3.1: Word-Level State Tracking**
- **File**: `pv-demo/src/engine/PVEngine.ts` (MODIFY)
- **Dependencies**: Phase 2 complete
- **TDD**: Test state transitions at word boundaries

**New State Tracking:**
```typescript
// Add to PVEngine class
private currentLine: LyricLine | null = null;
private currentCharIndex: number = 0;
private charStates: Map<number, 'future' | 'active' | 'done'> = new Map();

getCharState(charIndex: number, currentTime: number): CharState {
  const line = this.currentLine;
  if (!line || !line.chars) return 'future';
  
  const char = line.chars[charIndex];
  if (!char) return 'future';
  
  if (currentTime < char.time) return 'future';
  if (char.duration && currentTime >= char.time + char.duration) return 'done';
  return 'active';
}

// Calculate animation progress for active word (0.0 - 1.0)
getCharProgress(charIndex: number, currentTime: number): number {
  const line = this.currentLine;
  if (!line || !line.chars) return 0;
  
  const char = line.chars[charIndex];
  if (!char || currentTime < char.time) return 0;
  
  const duration = char.duration || (line.endTime ? line.endTime - char.time : 0.5);
  const progress = (currentTime - char.time) / duration;
  return Math.min(1, Math.max(0, progress));
}
```

**Task 3.2: HeroText Effect - Word Animation**
- **File**: `pv-demo/src/effects/HeroTextEffect.ts` (NEW/MODIFY)
- **Dependencies**: Task 3.1
- **TDD**: Visual test with word-level lyrics

**Rendering Strategy:**
```typescript
// Hero text with word-by-word animation
class HeroTextEffect {
  render(time: number, lyricData: { text: string; chars?: LyricChar[]; charIndex?: number }) {
    if (!lyricData.chars) {
      // Line-level fallback: use existing implementation
      return this.renderLineLevel(lyricData.text);
    }
    
    // Word-level: render each word with individual animation
    const container = new Container();
    
    lyricData.chars.forEach((char, index) => {
      const state = this.engine.getCharState(index, time);
      const progress = this.engine.getCharProgress(index, time);
      
      const wordSprite = this.createWordSprite(char.text, state, progress);
      container.addChild(wordSprite);
    });
    
    return container;
  }
  
  createWordSprite(text: string, state: CharState, progress: number) {
    const style = new TextStyle({ /* ... */ });
    const sprite = new Text(text, style);
    
    switch (state) {
      case 'future':
        // Not yet sung: subtle, grayed out
        sprite.alpha = 0.3;
        sprite.filters = [new BlurFilter(2)];
        break;
        
      case 'active':
        // Currently being sung: smooth appearance animation
        // Use progress to drive animation
        sprite.alpha = 0.3 + (progress * 0.7); // Fade in
        const scale = 1 + (Math.sin(progress * Math.PI) * 0.05); // Subtle pulse
        sprite.scale.set(scale);
        sprite.filters = []; // Remove blur as it becomes active
        break;
        
      case 'done':
        // Already sung: fully visible
        sprite.alpha = 1.0;
        sprite.scale.set(1);
        break;
    }
    
    return sprite;
  }
}
```

**Task 3.3: GlowTextCards Effect - Word Animation**
- **File**: `pv-demo/src/effects/GlowTextCardsEffect.ts` (NEW/MODIFY)
- **Dependencies**: Task 3.2
- **TDD**: Visual test with glow and word timing

**Animation Details:**
```typescript
// Glow text cards with per-word glow activation
class GlowTextCardsEffect {
  render(time: number, lyricData: { text: string; chars?: LyricChar[] }) {
    if (!lyricData.chars) {
      return this.renderLineLevel(lyricData.text);
    }
    
    const cards: Sprite[] = [];
    
    lyricData.chars.forEach((char, index) => {
      const state = this.engine.getCharState(index, time);
      const progress = this.engine.getCharProgress(index, time);
      
      // Each word is a card
      const card = this.createCard(char.text, index);
      
      if (state === 'active') {
        // Glow intensity based on progress
        const glowIntensity = this.config.glowAlpha * progress;
        card.filters = [new GlowFilter({
          color: this.config.glowColor,
          alpha: glowIntensity,
          blur: 10 * progress
        })];
        
        // Card highlight animation
        card.alpha = 0.5 + (progress * 0.5);
      } else if (state === 'done') {
        // Fully lit
        card.filters = [new GlowFilter({
          color: this.config.glowColor,
          alpha: this.config.glowAlpha,
          blur: 10
        })];
        card.alpha = 1.0;
      } else {
        // Future: dimmed
        card.alpha = 0.3;
        card.filters = [];
      }
      
      cards.push(card);
    });
    
    return cards;
  }
}
```

**Task 3.4: Other Effects Update**
- **Files**: Update all text effects in `pv-demo/src/effects/`
- **Dependencies**: Task 3.2, 3.3
- **Pattern**: Each effect checks for `chars` array and falls back to line-level

**Effects to Update:**
1. `scatteredText.ts` - Scatter words instead of chars
2. `layeredText.ts` - Layer words with stagger based on timing
3. `pixelTypewriter.ts` - Type each word with timing
4. Any other text-based effects

**Atomic Commit 3**: `feat(lyrics): word-by-word animation for heroText and glowTextCards`
- Includes: Updated effects with word-level support
- Includes: smooth animation transitions
- Verified: visual tests pass

**Atomic Commit 4**: `feat(lyrics): word animation support for remaining effects`
- Includes: scatteredText, layeredText, pixelTypewriter
- Verified: all effects work with both line and word-level

---

### PHASE 4: TESTING & VALIDATION

**Task 4.1: Unit Tests - Parsers**
- **File**: `pv-demo/src/parsers/__tests__/lrc.test.ts` (NEW)
- **File**: `pv-demo/src/parsers/__tests__/ttml.test.ts` (NEW)
- **File**: `pv-demo/src/parsers/__tests__/detect.test.ts` (NEW)

**Test Cases:**
```typescript
// LRC Parser Tests
describe('parseEnhancedLRC', () => {
  test('parses standard LRC', () => {
    const lrc = `[00:01.00]Line one\n[00:03.50]Line two`;
    const result = parseEnhancedLRC(lrc);
    expect(result).toHaveLength(2);
    expect(result[0]).toEqual({ time: 1.0, text: 'Line one' });
  });
  
  test('parses enhanced LRC with word timing', () => {
    const lrc = `[00:01.00]<00:01.00>Hello <00:01.50>world`;
    const result = parseEnhancedLRC(lrc);
    expect(result[0].chars).toHaveLength(2);
    expect(result[0].chars![0]).toEqual({ time: 1.0, text: 'Hello ', duration: 0.5 });
  });
  
  test('calculates end times for words', () => {
    // Word end time = next word start time
  });
  
  test('handles multiple timestamps per line', () => {
    // [00:01.00][00:03.00]Same line twice
  });
});

// TTML Parser Tests
describe('parseTTML', () => {
  test('parses TTML with word timing', () => {
    const ttml = `<?xml...><p begin="1:08.183" end="1:14.509"><span begin="1:08.183" end="1:09.221">春</span></p>`;
    const result = parseTTML(ttml);
    expect(result[0].chars).toHaveLength(1);
    expect(result[0].chars![0].time).toBe(68.183);
  });
  
  test('supports HH:MM:SS.mmm format', () => {
    // begin="00:01:08.183"
  });
  
  test('supports MM:SS.mmm format', () => {
    // begin="1:08.183"
  });
  
  test('filters out translation lines', () => {
    // Lines with itunes:translation="zh"
  });
  
  test('filters out bg lines', () => {
    // Background vocal lines
  });
  
  test('throws on invalid XML', () => {
    expect(() => parseTTML('not xml')).toThrow();
  });
  
  test('throws on malformed time', () => {
    // Invalid time format
  });
});

// Format Detection Tests
describe('detectLyricsFormat', () => {
  test('detects TTML by XML declaration', () => {
    expect(detectLyricsFormat('<?xml version="1.0"?>')).toBe('ttml');
  });
  
  test('detects TTML by tt tag', () => {
    expect(detectLyricsFormat('<tt xmlns="...">')).toBe('ttml');
  });
  
  test('detects LRC by time tags', () => {
    expect(detectLyricsFormat('[00:01.00]Hello')).toBe('lrc');
  });
  
  test('returns unknown for plain text', () => {
    expect(detectLyricsFormat('Just plain text')).toBe('unknown');
  });
});
```

**Task 4.2: Integration Tests - PVEngine**
- **File**: `pv-demo/src/engine/__tests__/PVEngine.test.ts` (NEW)

**Test Cases:**
```typescript
describe('PVEngine Word-Level Lyrics', () => {
  let engine: PVEngine;
  
  beforeEach(() => {
    engine = new PVEngine();
  });
  
  test('setLyricTimeline auto-detects TTML', () => {
    const ttml = `<?xml...><p begin="1:00" end="1:05"><span begin="1:00" end="1:02">Word</span></p>`;
    engine.setLyricTimeline(ttml);
    expect(engine.lyricTimeline[0].chars).toBeDefined();
  });
  
  test('setLyricTimeline auto-detects LRC', () => {
    const lrc = `[00:01.00]Hello world`;
    engine.setLyricTimeline(lrc);
    expect(engine.lyricTimeline[0].text).toBe('Hello world');
  });
  
  test('getDisplayText returns word-level data', () => {
    // Setup word-level lyrics
    // Verify returned structure has chars array
  });
  
  test('cursor advances correctly with word-level timing', () => {
    // Test that lyricCursor and currentCharIndex update correctly
  });
  
  test('backward seek resets cursor', () => {
    // Seek forward, then backward, verify cursor reset
  });
  
  test('performance: does not scan all lyrics every frame', () => {
    // Verify cursor-based approach is used
    // Mock getDisplayText and ensure it doesn't iterate full array
  });
});
```

**Task 4.3: Performance Tests**
- **File**: `pv-demo/src/__tests__/performance.test.ts` (NEW)

**Test Cases:**
```typescript
describe('Performance', () => {
  test('getDisplayText is O(1) average case', () => {
    // Create large timeline (10,000 lines)
    // Measure time for multiple calls
    // Ensure time doesn't grow with timeline size
  });
  
  test('word animation maintains 60fps', () => {
    // Simulate 60 frames with word-level lyrics
    // Measure total render time
    // Assert < 16.67ms per frame average
  });
  
  test('memory usage stable during playback', () => {
    // Check for memory leaks
    // Ensure no new objects created per frame
  });
});
```

**Task 4.4: Visual Regression Tests**
- **Setup**: Screenshot comparison for key animation frames
- **Files**: `pv-demo/e2e/lyrics-visual.test.ts` (NEW)

**Test Scenarios:**
1. Word-level animation at 25%, 50%, 75% progress
2. Line-level fallback renders correctly
3. All effects render without errors

**Task 4.5: Sample Files & Manual Testing**
- **File**: `pv-demo/samples/` directory (NEW)
- Create sample LRC files (standard and enhanced)
- Create sample TTML files (word-level timing)
- Create HTML test page for manual verification

**Atomic Commit 5**: `test(lyrics): comprehensive unit and integration tests`
- Includes: Parser tests, PVEngine tests
- Verified: all tests pass

**Atomic Commit 6**: `test(lyrics): performance and visual regression tests`
- Includes: Performance benchmarks
- Verified: 60fps maintained

---

## Parallel Execution Plan

### Work Streams (can run in parallel)

**Stream A: Parsers & Data Model**
1. Task 1.1: Enhanced Lyric Line Data Structure
2. Task 1.2: Enhanced LRC Parser
3. Task 1.4: Format Detection Utility
4. Task 4.1: Unit Tests - Parsers

**Stream B: TTML Parser**
1. Task 1.3: TTML Parser (parallel with Stream A tasks 2-4)
2. Task 4.1: TTML-specific tests

**Stream C: Engine Integration**
1. Task 2.1: Extend setLyricTimeline() (needs Stream A & B)
2. Task 2.2: Update getDisplayText() (needs Task 2.1)
3. Task 4.2: Integration Tests (needs Task 2.2)

**Stream D: Animation Effects**
1. Task 3.1: Word-Level State Tracking (needs Stream C)
2. Task 3.2: HeroText Effect (needs Task 3.1)
3. Task 3.3: GlowTextCards Effect (needs Task 3.1)
4. Task 4.3: Performance Tests (needs Tasks 3.2-3.3)

**Stream E: Remaining Effects**
1. Task 3.4: Other Effects Update (can be done in parallel with D after Task 3.1)

### Dependency Graph

```
Task 1.1 ─┬──> Task 1.2 ─┬──> Task 2.1 ─┬──> Task 2.2 ─┬──> Task 3.1 ─┬──> Task 3.2
          │              │              │              │              └──> Task 3.3
          │              │              │              │              └──> Task 3.4
          │              │              │              │
          └──> Task 1.4 ─┘              │              └──> Task 4.2
                                        │
Task 1.3 ───────────────────────────────┘              └──> Task 4.3

Task 4.1 (can start after 1.1, 1.2, 1.3, 1.4)
Task 4.4 (can start after 3.2, 3.3)
Task 4.5 (can be done anytime)
```

---

## Atomic Commit Strategy

### Commit 1: `feat(lyrics): unified data model and parsers`
**Scope**: Phase 1 (Tasks 1.1-1.4) + Tests 4.1
**Changes**:
- New files: `types.ts`, `lrc.ts`, `ttml.ts`, `detect.ts`
- Test files: `lrc.test.ts`, `ttml.test.ts`, `detect.test.ts`
**Verify**: `npm test -- parsers` passes

### Commit 2: `feat(lyrics): unified entry point with format auto-detection`
**Scope**: Phase 2 (Tasks 2.1-2.2) + Tests 4.2
**Changes**:
- Modify: `PVEngine.ts` - `setLyricTimeline()`, `getDisplayText()`
- New test: `PVEngine.test.ts`
**Verify**: `npm test -- PVEngine` passes

### Commit 3: `feat(lyrics): word-by-word animation for heroText and glowTextCards`
**Scope**: Phase 3 (Tasks 3.1-3.3) + Tests 4.3
**Changes**:
- Modify: `PVEngine.ts` - add state tracking
- New files: `HeroTextEffect.ts`, `GlowTextCardsEffect.ts` (refactored)
- New test: `performance.test.ts`
**Verify**: Visual tests pass, 60fps maintained

### Commit 4: `feat(lyrics): word animation support for remaining effects`
**Scope**: Phase 3 (Task 3.4)
**Changes**:
- Update: `scatteredText.ts`, `layeredText.ts`, `pixelTypewriter.ts`, etc.
**Verify**: All effects render correctly

### Commit 5: `test(lyrics): comprehensive unit and integration tests`
**Scope**: Phase 4 (Tasks 4.1-4.2)
**Changes**:
- Test files for all components
**Verify**: `npm test` passes (100% coverage)

### Commit 6: `test(lyrics): performance and visual regression tests`
**Scope**: Phase 4 (Tasks 4.3-4.5)
**Changes**:
- Performance benchmarks
- Visual regression suite
- Sample files
**Verify**: Performance thresholds met

---

## File Modification Summary

### NEW Files
```
pv-demo/
├── src/
│   ├── lyrics/
│   │   └── types.ts              # Task 1.1
│   ├── parsers/
│   │   ├── lrc.ts                # Task 1.2
│   │   ├── ttml.ts               # Task 1.3
│   │   ├── detect.ts             # Task 1.4
│   │   └── index.ts              # Exports
│   ├── effects/
│   │   ├── HeroTextEffect.ts     # Task 3.2 (refactored)
│   │   └── GlowTextCardsEffect.ts # Task 3.3 (refactored)
│   └── __tests__/
│       ├── parsers/
│       │   ├── lrc.test.ts       # Task 4.1
│       │   ├── ttml.test.ts      # Task 4.1
│       │   └── detect.test.ts    # Task 4.1
│       ├── engine/
│       │   └── PVEngine.test.ts  # Task 4.2
│       └── performance.test.ts   # Task 4.3
├── samples/
│   ├── standard.lrc              # Task 4.5
│   ├── enhanced.lrc              # Task 4.5
│   └── word-level.ttml           # Task 4.5
└── e2e/
    └── lyrics-visual.test.ts     # Task 4.4
```

### MODIFIED Files
```
pv-demo/src/engine/PVEngine.ts    # Tasks 2.1, 2.2, 3.1
pv-demo/src/effects/scatteredText.ts  # Task 3.4
pv-demo/src/effects/layeredText.ts    # Task 3.4
pv-demo/src/effects/pixelTypewriter.ts # Task 3.4
pv-demo/src/effects/index.ts          # Export updates
```

---

## Testing Strategy

### Unit Tests (per commit)
- Parser edge cases (empty lines, malformed input)
- Time format variations
- Format detection accuracy
- Data structure integrity

### Integration Tests (per commit)
- End-to-end LRC parsing → display
- End-to-end TTML parsing → display
- Cursor movement accuracy
- State transitions at boundaries

### Performance Tests (commit 6)
- Benchmark getDisplayText() with large datasets
- Frame rate monitoring during animation
- Memory profiling

### Visual Tests (commit 6)
- Screenshot comparison for each effect
- Animation smoothness verification
- Cross-browser compatibility

### Manual Testing Checklist
- [ ] Standard LRC renders correctly (backward compat)
- [ ] Enhanced LRC shows word animation
- [ ] TTML word timing displays correctly
- [ ] All 28 templates work with word-level lyrics
- [ ] Effects gracefully degrade without word timing
- [ ] Performance: 60fps on target hardware

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Backward incompatibility | Maintain line-level fallback in all effects |
| Performance regression | Cursor-based lookup, no array scanning |
| Parse errors | Explicit error messages, graceful degradation |
| Animation jank | Use CSS transforms/GPU acceleration, avoid layout thrashing |
| Memory leaks | Object pooling, no per-frame allocations |

---

## Success Criteria

1. **Functionality**: 
   - ✅ LRC and TTML parsing works
   - ✅ Word-level animation displays correctly
   - ✅ Backward compatibility maintained

2. **Performance**:
   - ✅ No regression in frame rate (maintain 60fps)
   - ✅ O(1) average lookup time for lyrics
   - ✅ Memory usage stable during playback

3. **Quality**:
   - ✅ 100% unit test coverage for parsers
   - ✅ All integration tests pass
   - ✅ Visual regression tests pass
   - ✅ No console errors

4. **Developer Experience**:
   - ✅ Clear error messages for parse failures
   - ✅ Type-safe TypeScript interfaces
   - ✅ Well-documented API

---

## Implementation Checklist

- [ ] Phase 1: Data Model & Parsers (Commits 1)
- [ ] Phase 2: Unified Entry Point (Commit 2)
- [ ] Phase 3: Word-Level Animation (Commits 3-4)
- [ ] Phase 4: Testing & Validation (Commits 5-6)
- [ ] Documentation updated
- [ ] Sample files created
- [ ] Performance benchmarks run
- [ ] Visual regression tests pass

---

## Ready for Execution

This plan is ready for `/ulw-loop` execution. The atomic commit strategy ensures each phase is complete and tested before moving to the next. Parallel streams maximize efficiency while respecting dependencies.
