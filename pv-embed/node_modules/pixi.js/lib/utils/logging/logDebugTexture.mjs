import { RendererType } from '../../rendering/renderers/types.mjs';

"use strict";
async function logDebugTexture(texture, renderer, size = 200) {
  const base64 = await renderer.extract.base64(texture);
  if (renderer.type !== RendererType.CANVAS) {
    await renderer.encoder.commandFinished;
  }
  const width = size;
  console.log(`logging texture ${texture.source.width}px ${texture.source.height}px`);
  const style = [
    "font-size: 1px;",
    `padding: ${width}px ${300}px;`,
    `background: url(${base64}) no-repeat;`,
    "background-size: contain;"
  ].join(" ");
  console.log("%c ", style);
}

export { logDebugTexture };
//# sourceMappingURL=logDebugTexture.mjs.map
