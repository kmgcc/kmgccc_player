/**
 * AMLL Bridge - Swift <-> JavaScript Communication Layer
 * 
 * Provides stable APIs for native control and queues calls until ready.
 */

(function() {
    'use strict';
    
    // Redirect Console Log to Swift
    const originalLog = console.log;
    console.log = function() {
        // Call original
        originalLog.apply(console, arguments);
        
        // Format message
        const msg = Array.from(arguments).map(arg => {
            if (typeof arg === 'object') return JSON.stringify(arg);
            return String(arg);
        }).join(' ');
        
        // Updates debug overlay
        if (window.debugLog) window.debugLog(msg);
        
        // Send to Swift
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.log) {
            window.webkit.messageHandlers.log.postMessage(msg);
        }
    };
    
    const originalError = console.error;
    console.error = function() {
        originalError.apply(console, arguments);
        const msg = "[ERROR] " + Array.from(arguments).join(' ');
        if (window.debugLog) window.debugLog(msg);
        
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.log) {
            window.webkit.messageHandlers.log.postMessage(msg);
        }
    };
    
    // State
    let isReady = false;
    const pendingCalls = [];

    const sha256Hex = async function(text) {
        if (!window.crypto || !window.crypto.subtle || typeof TextEncoder === 'undefined') {
            return null;
        }
        const bytes = new TextEncoder().encode(text);
        const digest = await window.crypto.subtle.digest('SHA-256', bytes);
        const view = new Uint8Array(digest);
        return Array.from(view).map((b) => b.toString(16).padStart(2, '0')).join('');
    };

    const collectXBgNodes = function(ttmlText) {
        if (typeof ttmlText !== 'string' || ttmlText.trim().length === 0) {
            return [];
        }
        const doc = new DOMParser().parseFromString(ttmlText, 'application/xml');
        if (doc.querySelector('parsererror')) {
            console.error('[Bridge][TTML] parsererror while scanning x-bg nodes');
            return [];
        }
        return Array.from(doc.getElementsByTagName('*')).filter((el) => {
            if (el.localName !== 'span') return false;
            const role = el.getAttribute('ttm:role')
                || el.getAttributeNS('http://www.w3.org/ns/ttml#metadata', 'role')
                || el.getAttribute('role');
            return role === 'x-bg';
        }).map((node) => {
            const words = Array.from(node.children)
                .filter((child) => child.localName === 'span')
                .map((child) => ({
                    begin: child.getAttribute('begin'),
                    end: child.getAttribute('end'),
                    text: (child.textContent || '').trim(),
                }));
            return {
                begin: node.getAttribute('begin'),
                end: node.getAttribute('end'),
                words,
            };
        });
    };

    const logTTMLDiagnostics = function(ttmlText, stage) {
        const text = typeof ttmlText === 'string' ? ttmlText : String(ttmlText ?? '');
        console.log(`[Bridge][TTML][${stage}] len=${text.length}`);

        sha256Hex(text).then((hash) => {
            if (hash) {
                console.log(`[Bridge][TTML][${stage}] sha256=${hash}`);
            } else {
                console.warn(`[Bridge][TTML][${stage}] sha256 unavailable`);
            }
        }).catch((err) => {
            console.error('[Bridge][TTML] sha256 error', err);
        });

        const xbgNodes = collectXBgNodes(text);
        console.log(`[Bridge][TTML][${stage}] x-bg count=${xbgNodes.length}`);
        xbgNodes.forEach((item, idx) => {
            const previewWords = item.words.slice(0, 12).map((word, wi) => (
                `#${wi}(${word.begin}~${word.end})${word.text}`
            ));
            const suffix = item.words.length > 12 ? ` ...(+${item.words.length - 12} words)` : '';
            console.log(
                `[Bridge][TTML][${stage}] x-bg#${idx} begin=${item.begin} end=${item.end} words=${item.words.length} ${previewWords.join(' | ')}${suffix}`
            );
        });
    };
    
    // AMLL namespace
    window.AMLL = {
        version: '1.0.0',
        capabilities: ['ttml', 'lrc', 'seek'],
        
        /**
         * Set TTML lyrics text
         * @param {string} ttmlText - Raw TTML/LRC content
         */
        setLyricsTTML: function(ttmlText) {
            try {
                if (window.updateDebugTTML) window.updateDebugTTML(ttmlText ? ttmlText.length : 0);
                logTTMLDiagnostics(ttmlText, 'setLyricsTTML');
                
                if (!isReady) {
                    pendingCalls.push({ method: 'setLyricsTTML', args: [ttmlText] });
                    return;
                }
                console.log("[Bridge] setLyricsTTML, length:", ttmlText ? ttmlText.length : 0);
                
                if (window.LyricsRenderer && typeof window.LyricsRenderer.setLyrics === 'function') {
                    window.LyricsRenderer.setLyrics(ttmlText);
                } else {
                    console.warn("[Bridge] LyricsRenderer.setLyrics NOT found");
                }
            } catch (e) {
                console.error("[Bridge-Crash] setLyricsTTML:", e);
                // Report back to native if possible
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.log) {
                    window.webkit.messageHandlers.log.postMessage("Bridge-Crash: " + e.toString());
                }
            }
        },
        
        setCurrentTime: function(seconds) {
            try {
                if (window.updateDebugTime) window.updateDebugTime(seconds);

                if (!isReady) {
                    return;
                }
                if (window.LyricsRenderer && typeof window.LyricsRenderer.setCurrentTime === 'function') {
                    window.LyricsRenderer.setCurrentTime(seconds);
                }
            } catch (e) {
                console.error("[Bridge-Crash] setCurrentTime:", e);
            }
        },
        
        setPlaying: function(isPlaying) {
            try {
                if (!isReady) {
                    pendingCalls.push({ method: 'setPlaying', args: [isPlaying] });
                    return;
                }
                if (window.LyricsRenderer && typeof window.LyricsRenderer.setPlaying === 'function') {
                    window.LyricsRenderer.setPlaying(isPlaying);
                }
            } catch (e) {
                 console.error("[Bridge-Crash] setPlaying:", e);
            }
        },
        
        setConfig: function(config) {
            try {
                if (!isReady) {
                    pendingCalls.push({ method: 'setConfig', args: [config] });
                    return;
                }
                if (window.LyricsRenderer && typeof window.LyricsRenderer.setConfig === 'function') {
                    window.LyricsRenderer.setConfig(config);
                }
            } catch (e) {
                 console.error("[Bridge-Crash] setConfig:", e);
            }
        },
        
        /**
         * Called internally when renderer is ready
         */
        _onRendererReady: function() {
            isReady = true;
            if (window.updateDebugStatus) window.updateDebugStatus("Renderer Ready");
            
            // Notify Swift that we're ready
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.onReady) {
                window.webkit.messageHandlers.onReady.postMessage({
                    version: window.AMLL.version,
                    capabilities: window.AMLL.capabilities
                });
            } else {
                console.warn("[Bridge] Cannot Notify Swift (onReady handler missing)");
            }
            
            // Flush pending calls
            console.log('[Bridge] Flushing ' + pendingCalls.length + ' calls');
            
            const callsToFlush = pendingCalls.slice();
            pendingCalls.length = 0;
            
            callsToFlush.forEach(function(call) {
                window.AMLL[call.method].apply(window.AMLL, call.args);
            });
            
            console.log('[Bridge] Ready and flushed');
        },
        
        /**
         * Called by renderer when user seeks
         * @param {number} seconds - Seek target time
         */
        _onUserSeek: function(seconds) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.onUserSeek) {
                window.webkit.messageHandlers.onUserSeek.postMessage({ seconds: seconds });
            }
        }
    };
    
    console.log('[Bridge] Initialized');
    
})();
