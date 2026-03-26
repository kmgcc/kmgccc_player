// PV TTML Word-by-Word Rendering - Canvas Overlay + Effect Control
// Controls text effects to prevent overlap with word-by-word rendering

(function() {
  'use strict';
  
  function waitForPV() {
    if (window.PVEngine && window.PVApi && window.PVEngine.app) {
      initTTMLRendering();
    } else {
      setTimeout(waitForPV, 50);
    }
  }
  
  function initTTMLRendering() {
    console.log('[TTMLRenderer] Initializing...');
    
    const engine = window.PVEngine;
    
    // ===== TTML PARSER =====
    const TTMLParser = {
      parseTime(timeStr) {
        if (!timeStr) return null;
        timeStr = String(timeStr).trim();
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
        const seconds = parseFloat(timeStr);
        return isNaN(seconds) ? null : seconds;
      },
      
      parse(ttmlText) {
        const result = [];
        try {
          const parser = new DOMParser();
          const doc = parser.parseFromString(ttmlText, 'application/xml');
          if (doc.querySelector('parsererror')) throw new Error('Invalid TTML XML');
          
          const paragraphs = doc.querySelectorAll('p');
          for (const p of paragraphs) {
            if (p.getAttribute('ttm:agent') === 'v2') continue;
            if (p.getAttribute('ttm:role') === 'translation') continue;
            
            const begin = this.parseTime(p.getAttribute('begin'));
            const end = this.parseTime(p.getAttribute('end'));
            if (begin === null) continue;
            
            const spans = Array.from(p.querySelectorAll(':scope > span'));
            const chars = [];
            const mainSpans = spans.filter(s => s.getAttribute('ttm:role') !== 'x-bg');
            
            if (mainSpans.length > 0) {
              for (const span of mainSpans) {
                const wordBegin = this.parseTime(span.getAttribute('begin'));
                const wordEnd = this.parseTime(span.getAttribute('end'));
                const text = span.textContent || '';
                if (wordBegin !== null && text) {
                  chars.push({
                    time: wordBegin,
                    endTime: wordEnd || wordBegin + 0.5,
                    duration: wordEnd ? wordEnd - wordBegin : 0.5,
                    text
                  });
                }
              }
            }
            
            const lineText = chars.length > 0 ? chars.map(c => c.text).join('') : (p.textContent?.trim() || '');
            if (lineText) {
              const line = { time: begin, text: lineText };
              if (chars.length > 0) {
                line.chars = chars;
                line.endTime = end || chars[chars.length - 1].endTime;
                line.hasChars = true;
              } else {
                line.endTime = end || begin + 3;
                line.hasChars = false;
              }
              result.push(line);
            }
          }
          result.sort((a, b) => a.time - b.time);
        } catch (error) {
          console.error('[TTMLParser] Error:', error);
          throw error;
        }
        return result;
      }
    };
    
    // ===== WORD ANIMATION =====
    const WordAnimator = {
      getCharState(char, currentTime) {
        if (currentTime < char.time) return { state: 'future', progress: 0 };
        if (currentTime >= char.endTime) return { state: 'done', progress: 1 };
        return { state: 'active', progress: (currentTime - char.time) / (char.endTime - char.time) };
      },
      
      getCurrentLine(timeline, currentTime, offset) {
        if (!timeline || timeline.length === 0) return null;
        const adjustedTime = Math.max(0, currentTime + offset);
        for (const line of timeline) {
          if (adjustedTime >= line.time && adjustedTime < line.endTime) {
            const result = { text: line.text, hasChars: !!line.chars };
            if (line.chars) {
              result.chars = line.chars.map(c => ({ ...c, ...this.getCharState(c, adjustedTime) }));
            }
            return result;
          }
        }
        return null;
      }
    };
    
    // ===== STATE =====
    engine._ttmlTimeline = null;
    engine._hasTTML = false;
    engine._hasCharLevel = false;
    engine._currentTTMLLine = null;
    engine._wordRenderActive = false;
    
    const originalSetLyricTimeline = engine.setLyricTimeline.bind(engine);
    const originalGetDisplayText = engine.getDisplayText.bind(engine);
    const originalUpdate = engine.update.bind(engine);
    const originalLoadTemplate = engine.loadTemplate.bind(engine);
    
    engine.setLyricTimeline = function(timeline) {
      if (timeline.length > 0 && timeline[0].endTime !== undefined) {
        this._ttmlTimeline = timeline;
        this._hasTTML = true;
        this._hasCharLevel = timeline.some(l => l.chars);
        console.log('[PVEngine] TTML:', timeline.length, 'lines, charLevel:', this._hasCharLevel);
      } else {
        this._ttmlTimeline = null;
        this._hasTTML = false;
        this._hasCharLevel = false;
      }
      return originalSetLyricTimeline(timeline);
    };
    
    // Override getDisplayText to hide text when word render is active
    engine.getDisplayText = function(t) {
      if (!this._hasTTML || !this._ttmlTimeline) return originalGetDisplayText(t);
      
      const line = WordAnimator.getCurrentLine(this._ttmlTimeline, t, this.lyricOffsetSeconds);
      if (line) {
        this._currentTTMLLine = line;
        // If has chars and word render active, return empty to hide original effect text
        if (line.hasChars && this._wordRenderActive) return '';
        return line.text;
      }
      return '';
    };
    
    // ===== WORD RENDERER (Canvas) =====
    const wordCanvas = document.createElement('canvas');
    wordCanvas.id = 'pv-word-canvas';
    wordCanvas.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:50;';
    document.body.appendChild(wordCanvas);
    const ctx = wordCanvas.getContext('2d');
    
    let lastRenderedText = '';
    let charWidths = [];
    
    function resizeCanvas() {
      wordCanvas.width = window.innerWidth;
      wordCanvas.height = window.innerHeight;
    }
    resizeCanvas();
    window.addEventListener('resize', resizeCanvas);
    
    function renderWordLyrics() {
      ctx.clearRect(0, 0, wordCanvas.width, wordCanvas.height);
      
      const line = engine._currentTTMLLine;
      
      // Only render if we have char-level TTML
      if (!line || !line.hasChars || !engine._wordRenderActive) {
        return;
      }
      
      const palette = engine.palette || {};
      const color = palette.text || '#ffffff';
      
      ctx.font = '700 72px "Noto Sans JP", "Hiragino Sans", sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      
      const centerX = wordCanvas.width / 2;
      const centerY = wordCanvas.height / 2;
      
      // Calculate widths
      if (line.text !== lastRenderedText) {
        charWidths = line.chars.map(c => ctx.measureText(c.text).width);
        lastRenderedText = line.text;
      }
      
      const totalWidth = charWidths.reduce((a, b) => a + b, 0) + (line.chars.length - 1) * 2;
      let x = centerX - totalWidth / 2;
      
      line.chars.forEach((char, i) => {
        const width = charWidths[i];
        const charX = x + width / 2;
        
        ctx.save();
        
        if (char.state === 'future') {
          ctx.globalAlpha = 0.3;
          ctx.filter = 'blur(2px)';
        } else if (char.state === 'active') {
          const p = char.progress;
          ctx.globalAlpha = 0.3 + p * 0.7;
          ctx.filter = 'blur(' + (2 - p * 2) + 'px)';
          ctx.translate(0, (1 - p) * 5);
        } else {
          ctx.globalAlpha = 1;
        }
        
        ctx.fillStyle = color;
        ctx.shadowColor = 'rgba(255,255,255,0.3)';
        ctx.shadowBlur = 20;
        ctx.fillText(char.text, charX, centerY);
        
        ctx.restore();
        x += width + 2;
      });
    }
    
    // ===== MAIN UPDATE LOOP =====
    engine.update = function(t, deltaTime) {
      const time = this._npActive ? this._npTime : 
                   this.beat.isAudioMode ? this.beat.currentTime : t;
      
      if (this._hasTTML && this._ttmlTimeline) {
        const line = WordAnimator.getCurrentLine(
          this._ttmlTimeline, time, this.lyricOffsetSeconds || 0
        );
        
        // Determine if word render should be active
        // Word render is active when: we have char-level TTML AND current line has chars
        const shouldUseWordRender = engine._hasCharLevel && line?.hasChars;
        
        if (shouldUseWordRender !== engine._wordRenderActive) {
          engine._wordRenderActive = shouldUseWordRender;
          // Clear canvas when switching modes
          if (!shouldUseWordRender) {
            ctx.clearRect(0, 0, wordCanvas.width, wordCanvas.height);
          }
        }
        
        engine._currentTTMLLine = line;
      } else {
        engine._currentTTMLLine = null;
        engine._wordRenderActive = false;
        ctx.clearRect(0, 0, wordCanvas.width, wordCanvas.height);
      }
      
      originalUpdate(t, deltaTime);
      renderWordLyrics();
    };
    
    engine.loadTemplate = function(template) {
      lastRenderedText = '';
      ctx.clearRect(0, 0, wordCanvas.width, wordCanvas.height);
      return originalLoadTemplate(template);
    };
    
    // ===== API =====
    window.PVApi.setTTML = function(ttmlText) {
      try {
        const parsed = TTMLParser.parse(ttmlText);
        if (parsed.length > 0) {
          engine.setLyricTimeline(parsed);
          return true;
        }
      } catch (err) {
        console.error('[PVApi] TTML parse failed:', err);
        alert('TTML parse error: ' + err.message);
      }
      return false;
    };
    
    const originalSetLRC = window.PVApi.setLRC;
    window.PVApi.setLRC = function(input) {
      const trimmed = input.trim();
      if (trimmed.startsWith('<?xml') || trimmed.startsWith('<tt')) {
        return window.PVApi.setTTML(trimmed);
      }
      return originalSetLRC(input);
    };
    
    window.PVApi.testParseTTML = TTMLParser.parse;
    window.PVApi.getTTMLState = () => ({
      hasTTML: engine._hasTTML,
      hasCharLevel: engine._hasCharLevel,
      wordRenderActive: engine._wordRenderActive,
      currentLine: engine._currentTTMLLine
    });
    
    console.log('[TTMLRenderer] Initialized.');
    console.log('[TTMLRenderer] Char-level TTML will use Canvas word rendering.');
    console.log('[TTMLRenderer] Line-level TTML will use original effect rendering.');
  }
  
  waitForPV();
})();
