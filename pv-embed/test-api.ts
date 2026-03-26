// Test script for PV Embed API
import { PVEmbed } from './src/main.ts';

async function runTests() {
  console.log('=== PV Embed API Tests ===\n');
  
  // 创建容器
  const container = document.createElement('div');
  container.id = 'test-container';
  container.style.width = '800px';
  container.style.height = '600px';
  container.style.position = 'fixed';
  container.style.left = '-9999px';
  document.body.appendChild(container);
  
  const pv = new PVEmbed();
  
  // Test 1: Init
  console.log('Test 1: Init');
  try {
    await pv.init('test-container');
    console.log('✓ Init success');
  } catch (e) {
    console.error('✗ Init failed:', e);
    return;
  }
  
  // Test 2: Set Lyrics (LRC)
  console.log('\nTest 2: Set Lyrics (LRC)');
  const lrcText = `[00:00.00]第一行歌词
[00:03.00]第二行歌词
[00:06.00]第三行测试`;
  const lrcResult = pv.setLyrics(lrcText, 'lrc');
  console.log(lrcResult ? '✓ LRC loaded' : '✗ LRC failed');
  
  // Test 3: Set Current Time
  console.log('\nTest 3: Set Current Time');
  pv.setCurrentTime(1.5);
  const currentTime = pv.getCurrentTime();
  console.log(currentTime === 1.5 ? '✓ Time set correctly' : '✗ Time mismatch');
  
  // Test 4: Get Lyric State
  console.log('\nTest 4: Get Lyric State');
  const lyricState = pv.getLyricState();
  console.log(lyricState ? `✓ Lyric state: ${lyricState.currentLine?.text || 'null'}` : '✗ No lyric state');
  
  // Test 5: BPM
  console.log('\nTest 5: BPM Control');
  pv.setBPM(128);
  const bpm = pv.getBPM();
  console.log(bpm === 128 ? '✓ BPM set to 128' : '✗ BPM mismatch');
  
  // Test 6: Beat Reactivity
  console.log('\nTest 6: Beat Reactivity');
  pv.setBeatReactivity(0.8);
  const reactivity = pv.getBeatReactivity();
  console.log(reactivity === 0.8 ? '✓ Reactivity set to 0.8' : '✗ Reactivity mismatch');
  
  // Test 7: PostFX
  console.log('\nTest 7: PostFX');
  pv.setShake(0.5);
  pv.setZoom(0.3);
  pv.setGlitch(0.2);
  console.log('✓ PostFX values set');
  
  // Test 8: Template
  console.log('\nTest 8: Template Switch');
  pv.setTemplate('1'); // Glow template
  console.log('✓ Template switched to Glow');
  
  // Test 9: Play/Pause
  console.log('\nTest 9: Play/Pause');
  pv.play();
  console.log(pv.isPlaying ? '✓ Playing' : '✗ Not playing');
  pv.pause();
  console.log(!pv.isPlaying ? '✓ Paused' : '✗ Still playing');
  
  // Test 10: Media Info
  console.log('\nTest 10: Media Info');
  pv.setMedia({ title: 'Test Song', artist: 'Test Artist' });
  console.log('✓ Media info set');
  
  // Test 11: TTML Word-level (if available)
  console.log('\nTest 11: TTML Word-level');
  const ttmlWord = `<?xml version="1.0"?>
<tt xmlns="http://www.w3.org/ns/ttml">
<body>
<div>
<p begin="0.0" end="3.0">
<span begin="0.0" end="1.0">测</span>
<span begin="1.0" end="2.0">试</span>
<span begin="2.0" end="3.0">词</span>
</p>
</div>
</body>
</tt>`;
  const ttmlResult = pv.setLyrics(ttmlWord, 'ttml-word');
  console.log(ttmlResult ? '✓ TTML word loaded' : '✗ TTML word failed');
  
  pv.setCurrentTime(1.5);
  const wordState = pv.getLyricState();
  console.log(wordState?.isWordLevel ? '✓ Word-level active' : '✗ Not word-level');
  
  console.log('\n=== All Tests Complete ===');
  
  // Cleanup
  pv.destroy();
  container.remove();
}

runTests().catch(console.error);
