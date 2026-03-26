import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { Matrix } from '../../../maths/matrix/Matrix.mjs';
import { UniformGroup } from '../../../rendering/renderers/shared/shader/UniformGroup.mjs';
import { getAdjustedBlendModeBlend } from '../../../rendering/renderers/shared/state/getAdjustedBlendModeBlend.mjs';
import { State } from '../../../rendering/renderers/shared/state/State.mjs';
import { GCManagedHash } from '../../../utils/data/GCManagedHash.mjs';
import { color32BitToUniform } from '../../graphics/gpu/colorToUniform.mjs';
import { ParticleBuffer } from './ParticleBuffer.mjs';
import { ParticleShader } from './shader/ParticleShader.mjs';

"use strict";
class ParticleContainerPipe {
  /**
   * @param renderer - The renderer this sprite batch works for.
   * @param adaptor
   */
  constructor(renderer, adaptor) {
    /** @internal */
    this.state = State.for2d();
    /** Local uniforms that are used for rendering particles. */
    this.localUniforms = new UniformGroup({
      uTranslationMatrix: { value: new Matrix(), type: "mat3x3<f32>" },
      uColor: { value: new Float32Array(4), type: "vec4<f32>" },
      uRound: { value: 1, type: "f32" },
      uResolution: { value: [0, 0], type: "vec2<f32>" }
    });
    this.renderer = renderer;
    this.adaptor = adaptor;
    this.defaultShader = new ParticleShader();
    this.state = State.for2d();
    this._managedContainers = new GCManagedHash({ renderer, type: "renderable", name: "particleContainer" });
  }
  validateRenderable(_renderable) {
    return false;
  }
  addRenderable(renderable, instructionSet) {
    this.renderer.renderPipes.batch.break(instructionSet);
    instructionSet.add(renderable);
  }
  getBuffers(renderable) {
    return renderable._gpuData[this.renderer.uid] || this._initBuffer(renderable);
  }
  _initBuffer(renderable) {
    renderable._gpuData[this.renderer.uid] = new ParticleBuffer({
      size: renderable.particleChildren.length,
      properties: renderable._properties
    });
    this._managedContainers.add(renderable);
    return renderable._gpuData[this.renderer.uid];
  }
  updateRenderable(_renderable) {
  }
  execute(container) {
    const children = container.particleChildren;
    if (children.length === 0) {
      return;
    }
    const renderer = this.renderer;
    const buffer = this.getBuffers(container);
    container.texture || (container.texture = children[0].texture);
    const state = this.state;
    buffer.update(children, container._childrenDirty);
    container._childrenDirty = false;
    state.blendMode = getAdjustedBlendModeBlend(container.blendMode, container.texture._source);
    const uniforms = this.localUniforms.uniforms;
    const transformationMatrix = uniforms.uTranslationMatrix;
    container.worldTransform.copyTo(transformationMatrix);
    const globalUniformData = renderer.globalUniforms.globalUniformData;
    transformationMatrix.tx -= globalUniformData.offset.x;
    transformationMatrix.ty -= globalUniformData.offset.y;
    transformationMatrix.prepend(globalUniformData.projectionMatrix);
    uniforms.uResolution = globalUniformData.resolution;
    uniforms.uRound = renderer._roundPixels | container._roundPixels;
    color32BitToUniform(
      container.groupColorAlpha,
      uniforms.uColor,
      0
    );
    this.adaptor.execute(this, container);
  }
  /** Destroys the ParticleRenderer. */
  destroy() {
    this._managedContainers.destroy();
    this.renderer = null;
    if (this.defaultShader) {
      this.defaultShader.destroy();
      this.defaultShader = null;
    }
  }
}
/** @ignore */
ParticleContainerPipe.extension = {
  type: [
    ExtensionType.CanvasPipes
  ],
  name: "particle"
};

export { ParticleContainerPipe };
//# sourceMappingURL=ParticleContainerPipe.mjs.map
