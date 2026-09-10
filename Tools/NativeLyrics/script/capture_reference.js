// Pass this function to playwright-cli run-code, from Tools/NativeLyrics.
// The served APP source is unchanged; this adds a read-only reference in the test response.
async page => {
  await page.route('**/Resources/AMLL/index.html', async route => {
    const response = await route.fetch();
    const source = await response.text();
    const needle = 'const lyricPlayer = new LyricPlayer();';
    if (!source.includes(needle)) throw Error('AMLL instrumentation point changed; audit before capture');
    await route.fulfill({response,body:source.replace(needle,needle+' window.__parityPlayer = lyricPlayer;')});
  });
  await page.goto('http://127.0.0.1:8766/Tools/NativeLyrics/product-reference.html');
  await page.waitForFunction(() => !!window.reference);
  await page.evaluate(() => window.ready);
  await page.waitForFunction(() => reference.host.__parityPlayer.currentLyricGroups.every(g=>Math.abs(g.posY.getCurrentPosition()-g.top)<0.1));
  const result = await page.evaluate(() => {
    const p = reference.host.__parityPlayer;
    return {
      viewport:{width:760,height:720},
      groups:p.currentLyricGroups.map((g,index)=>({index,main:g.mainLine.getLine(),background:g.bgLine?.getLine() ?? null})),
      layout:p.currentLyricGroups.map((g,index)=>({index,y:g.posY.getCurrentPosition(),height:p.lyricGroupSize.get(g)?.[1],blur:g.blur,opacity:g.opacity,active:g.isActive})),
      configuration:{fontSize:38,fontWeight:700,translationFontSize:28.5,leadInMs:600,nearSwitchGapMs:160}
    };
  });
  const pendingDownload = page.waitForEvent('download');
  await page.evaluate(result => {
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{type:'application/json'}));
    link.download = 'app-oracle.json'; link.click();
  },result);
  await (await pendingDownload).saveAs('output/playwright/app-oracle.json');
  await page.screenshot({path:'output/playwright/app-reference.png'});
  return {groups:result.groups.length,output:'output/playwright/app-oracle.json'};
}
