'use strict';

var canvasUtils = require('../../../rendering/renderers/canvas/utils/canvasUtils.js');

"use strict";
class CanvasParticleContainerAdaptor {
  execute(particleContainerPipe, container) {
    const renderer = particleContainerPipe.renderer;
    const context = renderer.canvasContext.activeContext;
    const children = container.particleChildren;
    const texture = container.texture;
    context.save();
    renderer.canvasContext.setContextTransform(container.worldTransform, container.roundPixels);
    renderer.canvasContext.setBlendMode(container.groupBlendMode);
    const groupColorAlpha = container.groupColorAlpha;
    const filterAlpha = renderer.filter?.alphaMultiplier ?? 1;
    const groupAlpha = (groupColorAlpha >>> 24 & 255) / 255 * filterAlpha;
    for (let i = 0; i < children.length; i++) {
      const particle = children[i];
      const pTexture = particle.texture || texture;
      if (!pTexture?.source?.resource) continue;
      const color = particle.color;
      const alpha = (color >>> 24 & 255) / 255 * groupAlpha;
      if (alpha <= 0) continue;
      const bgr = color & 16777215;
      const tint = ((bgr & 255) << 16) + (bgr & 65280) + (bgr >> 16 & 255);
      let drawSource = pTexture.source.resource;
      if (tint !== 16777215) {
        drawSource = canvasUtils.canvasUtils.getTintedCanvas({ texture: pTexture }, tint);
      }
      const frame = pTexture.frame;
      const resolution = pTexture.source.resolution;
      const sx = frame.x * resolution;
      const sy = frame.y * resolution;
      const sw = frame.width * resolution;
      const sh = frame.height * resolution;
      context.globalAlpha = alpha;
      const dx = -particle.anchorX * frame.width;
      const dy = -particle.anchorY * frame.height;
      if (particle.rotation !== 0 || particle.scaleX !== 1 || particle.scaleY !== 1) {
        context.save();
        context.translate(particle.x, particle.y);
        context.rotate(particle.rotation);
        context.scale(particle.scaleX, particle.scaleY);
        context.drawImage(drawSource, sx, sy, sw, sh, dx, dy, frame.width, frame.height);
        context.restore();
      } else {
        context.drawImage(drawSource, sx, sy, sw, sh, particle.x + dx, particle.y + dy, frame.width, frame.height);
      }
    }
    context.restore();
  }
}

exports.CanvasParticleContainerAdaptor = CanvasParticleContainerAdaptor;
//# sourceMappingURL=CanvasParticleContainerAdaptor.js.map
