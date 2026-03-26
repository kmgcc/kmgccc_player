'use strict';

var Extensions = require('../../../extensions/Extensions.js');
var Matrix = require('../../../maths/matrix/Matrix.js');
var UniformGroup = require('../../../rendering/renderers/shared/shader/UniformGroup.js');
var getAdjustedBlendModeBlend = require('../../../rendering/renderers/shared/state/getAdjustedBlendModeBlend.js');
var State = require('../../../rendering/renderers/shared/state/State.js');
var GCManagedHash = require('../../../utils/data/GCManagedHash.js');
var colorToUniform = require('../../graphics/gpu/colorToUniform.js');
var ParticleBuffer = require('./ParticleBuffer.js');
var ParticleShader = require('./shader/ParticleShader.js');

"use strict";
class ParticleContainerPipe {
  /**
   * @param renderer - The renderer this sprite batch works for.
   * @param adaptor
   */
  constructor(renderer, adaptor) {
    /** @internal */
    this.state = State.State.for2d();
    /** Local uniforms that are used for rendering particles. */
    this.localUniforms = new UniformGroup.UniformGroup({
      uTranslationMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uColor: { value: new Float32Array(4), type: "vec4<f32>" },
      uRound: { value: 1, type: "f32" },
      uResolution: { value: [0, 0], type: "vec2<f32>" }
    });
    this.renderer = renderer;
    this.adaptor = adaptor;
    this.defaultShader = new ParticleShader.ParticleShader();
    this.state = State.State.for2d();
    this._managedContainers = new GCManagedHash.GCManagedHash({ renderer, type: "renderable", name: "particleContainer" });
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
    renderable._gpuData[this.renderer.uid] = new ParticleBuffer.ParticleBuffer({
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
    state.blendMode = getAdjustedBlendModeBlend.getAdjustedBlendModeBlend(container.blendMode, container.texture._source);
    const uniforms = this.localUniforms.uniforms;
    const transformationMatrix = uniforms.uTranslationMatrix;
    container.worldTransform.copyTo(transformationMatrix);
    const globalUniformData = renderer.globalUniforms.globalUniformData;
    transformationMatrix.tx -= globalUniformData.offset.x;
    transformationMatrix.ty -= globalUniformData.offset.y;
    transformationMatrix.prepend(globalUniformData.projectionMatrix);
    uniforms.uResolution = globalUniformData.resolution;
    uniforms.uRound = renderer._roundPixels | container._roundPixels;
    colorToUniform.color32BitToUniform(
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
    Extensions.ExtensionType.CanvasPipes
  ],
  name: "particle"
};

exports.ParticleContainerPipe = ParticleContainerPipe;
//# sourceMappingURL=ParticleContainerPipe.js.map
