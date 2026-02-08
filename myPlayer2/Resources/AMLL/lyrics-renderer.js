/**
 * AMLL Lyrics Renderer
 * 
 * Parses TTML/LRC lyrics and renders with time-synced highlighting.
 */

(function() {
    'use strict';
    
    const container = document.getElementById('lyrics-container');
    const emptyState = document.getElementById('empty-state');
    
    let lyrics = [];
    let currentTime = 0;
    let isPlaying = false;
    let activeLine = -1;
    
    // Configuration
    let config = {
        fontSize: 24,
        fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif',
        activeColor: 'rgba(255, 255, 255, 1.0)',
        inactiveColor: 'rgba(255, 255, 255, 0.5)'
    };
    
    /**
     * Parse lyrics (supports simple LRC and TTML-like formats)
     */
    function parseLyrics(text) {
        console.log("[LyricsRenderer] Parsing lyrics, length:", text ? text.length : 0);
        try {
            if (!text || text.trim().length === 0) {
                return [];
            }
            
            const lines = [];
            
            // Check if it's TTML format
            if (text.includes('<tt') || text.includes('<p ')) {
                // Simple TTML parsing
                const pRegex = /<p[^>]*begin="([^"]+)"[^>]*end="([^"]+)"[^>]*>([^<]*)<\/p>/gi;
                let match;
                while ((match = pRegex.exec(text)) !== null) {
                    try {
                        const beginTime = parseTimeString(match[1]);
                        const endTime = parseTimeString(match[2]);
                        const content = match[3].trim();
                        if (content) {
                            lines.push({ start: beginTime, end: endTime, text: content });
                        }
                    } catch (err) {
                        console.warn("[LyricsRenderer] Failed to parse line:", match[0], err);
                    }
                }
            } else {
                // LRC format: [mm:ss.xx] text
                const lrcRegex = /\[(\d{1,2}):(\d{2})\.(\d{2,3})\](.*)/g;
                let match;
                while ((match = lrcRegex.exec(text)) !== null) {
                    const minutes = parseInt(match[1], 10);
                    const seconds = parseInt(match[2], 10);
                    const ms = parseInt(match[3].padEnd(3, '0'), 10);
                    const time = minutes * 60 + seconds + ms / 1000;
                    const content = match[4].trim();
                    if (content) {
                        lines.push({ start: time, end: time + 5, text: content });
                    }
                }
                
                // Calculate end times based on next line start
                for (let i = 0; i < lines.length - 1; i++) {
                    lines[i].end = lines[i + 1].start;
                }
                if (lines.length > 0) {
                    lines[lines.length - 1].end = lines[lines.length - 1].start + 10;
                }
            }
            
            console.log("[LyricsRenderer] Parsed lines:", lines.length);
            return lines.sort((a, b) => a.start - b.start);
        } catch (e) {
            console.error("[LyricsRenderer] Parse Crash:", e);
            return [];
        }
    }
    
    /**
     * Parse TTML time string (e.g., "00:01:23.456" or "83.456s")
     */
    function parseTimeString(str) {
        if (str.endsWith('s')) {
            return parseFloat(str.slice(0, -1));
        }
        
        const parts = str.split(':').map(parseFloat);
        if (parts.length === 3) {
            return parts[0] * 3600 + parts[1] * 60 + parts[2];
        } else if (parts.length === 2) {
            return parts[0] * 60 + parts[1];
        }
        return parseFloat(str) || 0;
    }
    
    /**
     * Render lyrics to DOM
     */
    function renderLyrics() {
        // Clear container
        container.innerHTML = '';
        
        if (lyrics.length === 0) {
            container.innerHTML = `
                <div id="empty-state">
                    <div class="icon">♪</div>
                    <div class="message">No lyrics loaded</div>
                </div>
            `;
            return;
        }
        
        lyrics.forEach((line, index) => {
            const div = document.createElement('div');
            div.className = 'lyric-line future';
            div.textContent = line.text;
            div.dataset.index = index;
            div.dataset.start = line.start;
            div.style.fontSize = config.fontSize + 'px';
            
            div.addEventListener('click', function() {
                const seconds = parseFloat(this.dataset.start);
                window.AMLL._onUserSeek(seconds);
            });
            
            container.appendChild(div);
        });
        
        updateActiveLine();
    }
    
    /**
     * Find and highlight active line based on current time
     */
    function updateActiveLine() {
        if (lyrics.length === 0) return;
        
        // Find active line
        let newActiveLine = -1;
        for (let i = lyrics.length - 1; i >= 0; i--) {
            if (currentTime >= lyrics[i].start) {
                newActiveLine = i;
                break;
            }
        }
        
        if (newActiveLine === activeLine) return;
        
        activeLine = newActiveLine;
        
        // Update all line classes
        const lines = container.querySelectorAll('.lyric-line');
        lines.forEach((line, index) => {
            line.classList.remove('active', 'past', 'future');
            if (index === activeLine) {
                line.classList.add('active');
            } else if (index < activeLine) {
                line.classList.add('past');
            } else {
                line.classList.add('future');
            }
        });
        
        // Scroll active line into view
        if (activeLine >= 0 && lines[activeLine]) {
            lines[activeLine].scrollIntoView({
                behavior: 'smooth',
                block: 'center'
            });
        }
    }
    
    // Public API
    window.LyricsRenderer = {
        setLyrics: function(text) {
            lyrics = parseLyrics(text);
            activeLine = -1;
            renderLyrics();
            console.log('[LyricsRenderer] Loaded', lyrics.length, 'lines');
        },
        
        setCurrentTime: function(seconds) {
            currentTime = seconds;
            updateActiveLine();
        },
        
        setPlaying: function(playing) {
            isPlaying = playing;
        },
        
        setConfig: function(newConfig) {
            Object.assign(config, newConfig);
            renderLyrics();
        }
    };
    
    // Mark ready after a short delay to ensure DOM is ready
    setTimeout(function() {
        window.AMLL._onRendererReady();
    }, 100);
    
    console.log('[LyricsRenderer] Initialized');
})();
