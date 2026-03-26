'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var Matrix = require('../../../../maths/matrix/Matrix.js');
var Point = require('../../../../maths/point/Point.js');
var colorToUniform = require('../../../../scene/graphics/gpu/colorToUniform.js');
var BindGroup = require('../../gpu/shader/BindGroup.js');
var types = require('../../types.js');
var UniformGroup = require('../shader/UniformGroup.js');

"use strict";
class GlobalUniformSystem {
  constructor(renderer) {
    this._stackIndex = 0;
    this._globalUniformDataStack = [];
    this._uniformsPool = [];
    this._activeUniforms = [];
    this._bindGroupPool = [];
    this._activeBindGroups = [];
    this._renderer = renderer;
  }
  reset() {
    this._stackIndex = 0;
    for (let i = 0; i < this._activeUniforms.length; i++) {
      this._uniformsPool.push(this._activeUniforms[i]);
    }
    for (let i = 0; i < this._activeBindGroups.length; i++) {
      this._bindGroupPool.push(this._activeBindGroups[i]);
    }
    this._activeUniforms.length = 0;
    this._activeBindGroups.length = 0;
  }
  start(options) {
    this.reset();
    this.push(options);
  }
  bind({
    size,
    projectionMatrix,
    worldTransformMatrix,
    worldColor,
    offset
  }) {
    const renderTarget = this._renderer.renderTarget.renderTarget;
    const currentGlobalUniformData = this._stackIndex ? this._globalUniformDataStack[this._stackIndex - 1] : {
      projectionData: renderTarget,
      worldTransformMatrix: new Matrix.Matrix(),
      worldColor: 4294967295,
      offset: new Point.Point()
    };
    const globalUniformData = {
      projectionMatrix: projectionMatrix || this._renderer.renderTarget.projectionMatrix,
      resolution: size || renderTarget.size,
      worldTransformMatrix: worldTransformMatrix || currentGlobalUniformData.worldTransformMatrix,
      worldColor: worldColor || currentGlobalUniformData.worldColor,
      offset: offset || currentGlobalUniformData.offset,
      bindGroup: null
    };
    const uniformGroup = this._uniformsPool.pop() || this._createUniforms();
    this._activeUniforms.push(uniformGroup);
    const uniforms = uniformGroup.uniforms;
    uniforms.uProjectionMatrix = globalUniformData.projectionMatrix;
    uniforms.uResolution = globalUniformData.resolution;
    uniforms.uWorldTransformMatrix.copyFrom(globalUniformData.worldTransformMatrix);
    uniforms.uWorldTransformMatrix.tx -= globalUniformData.offset.x;
    uniforms.uWorldTransformMatrix.ty -= globalUniformData.offset.y;
    colorToUniform.color32BitToUniform(
      globalUniformData.worldColor,
      uniforms.uWorldColorAlpha,
      0
    );
    uniformGroup.update();
    let bindGroup;
    if (this._renderer.renderPipes.uniformBatch) {
      bindGroup = this._renderer.renderPipes.uniformBatch.getUniformBindGroup(uniformGroup, false);
    } else {
      bindGroup = this._bindGroupPool.pop() || new BindGroup.BindGroup();
      this._activeBindGroups.push(bindGroup);
      bindGroup.setResource(uniformGroup, 0);
    }
    globalUniformData.bindGroup = bindGroup;
    this._currentGlobalUniformData = globalUniformData;
  }
  push(options) {
    this.bind(options);
    this._globalUniformDataStack[this._stackIndex++] = this._currentGlobalUniformData;
  }
  pop() {
    this._currentGlobalUniformData = this._globalUniformDataStack[--this._stackIndex - 1];
    if (this._renderer.type === types.RendererType.WEBGL) {
      this._currentGlobalUniformData.bindGroup.resources[0].update();
    }
  }
  get bindGroup() {
    return this._currentGlobalUniformData.bindGroup;
  }
  get globalUniformData() {
    return this._currentGlobalUniformData;
  }
  get uniformGroup() {
    return this._currentGlobalUniformData.bindGroup.resources[0];
  }
  _createUniforms() {
    const globalUniforms = new UniformGroup.UniformGroup({
      uProjectionMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      uWorldTransformMatrix: { value: new Matrix.Matrix(), type: "mat3x3<f32>" },
      // TODO - someone smart - set this to be a unorm8x4 rather than a vec4<f32>
      uWorldColorAlpha: { value: new Float32Array(4), type: "vec4<f32>" },
      uResolution: { value: [0, 0], type: "vec2<f32>" }
    }, {
      isStatic: true
    });
    return globalUniforms;
  }
  destroy() {
    this._renderer = null;
    this._globalUniformDataStack.length = 0;
    this._uniformsPool.length = 0;
    this._activeUniforms.length = 0;
    this._bindGroupPool.length = 0;
    this._activeBindGroups.length = 0;
    this._currentGlobalUniformData = null;
  }
}
/** @ignore */
GlobalUniformSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem,
    Extensions.ExtensionType.WebGPUSystem,
    Extensions.ExtensionType.CanvasSystem
  ],
  name: "globalUniforms"
};

exports.GlobalUniformSystem = GlobalUniformSystem;
//# sourceMappingURL=GlobalUniformSystem.js.map
