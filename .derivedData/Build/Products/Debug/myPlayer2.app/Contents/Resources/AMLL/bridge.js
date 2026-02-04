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
