'use strict';

"use strict";
class GlParticleContainerAdaptor {
  execute(particleContainerPipe, container) {
    const state = particleContainerPipe.state;
    const renderer = particleContainerPipe.renderer;
    const shader = container.shader || particleContainerPipe.defaultShader;
    shader.resources.uTexture = container.texture._source;
    shader.resources.uniforms = particleContainerPipe.localUniforms;
    const gl = renderer.gl;
    const buffer = particleContainerPipe.getBuffers(container);
    renderer.shader.bind(shader);
    renderer.state.set(state);
    renderer.geometry.bind(buffer.geometry, shader.glProgram);
    const byteSize = buffer.geometry.indexBuffer.data.BYTES_PER_ELEMENT;
    const glType = byteSize === 2 ? gl.UNSIGNED_SHORT : gl.UNSIGNED_INT;
    gl.drawElements(gl.TRIANGLES, container.particleChildren.length * 6, glType, 0);
  }
}

exports.GlParticleContainerAdaptor = GlParticleContainerAdaptor;
//# sourceMappingURL=GlParticleContainerAdaptor.js.map
