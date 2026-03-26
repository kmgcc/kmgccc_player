'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var GenerateShaderSyncCode = require('./GenerateShaderSyncCode.js');
var generateProgram = require('./program/generateProgram.js');

"use strict";
const defaultSyncData = {
  textureCount: 0,
  blockIndex: 0
};
class GlShaderSystem {
  constructor(renderer) {
    /** @internal */
    this._activeProgram = null;
    this._programDataHash = /* @__PURE__ */ Object.create(null);
    this._shaderSyncFunctions = /* @__PURE__ */ Object.create(null);
    this._renderer = renderer;
  }
  contextChange(gl) {
    this._gl = gl;
    this._programDataHash = /* @__PURE__ */ Object.create(null);
    this._shaderSyncFunctions = /* @__PURE__ */ Object.create(null);
    this._activeProgram = null;
  }
  /**
   * Changes the current shader to the one given in parameter.
   * @param shader - the new shader
   * @param skipSync - false if the shader should automatically sync its uniforms.
   * @returns the glProgram that belongs to the shader.
   */
  bind(shader, skipSync) {
    this._setProgram(shader.glProgram);
    if (skipSync) return;
    defaultSyncData.textureCount = 0;
    defaultSyncData.blockIndex = 0;
    let syncFunction = this._shaderSyncFunctions[shader.glProgram._key];
    if (!syncFunction) {
      syncFunction = this._shaderSyncFunctions[shader.glProgram._key] = this._generateShaderSync(shader, this);
    }
    this._renderer.buffer.nextBindBase(!!shader.glProgram.transformFeedbackVaryings);
    syncFunction(this._renderer, shader, defaultSyncData);
  }
  /**
   * Updates the uniform group.
   * @param uniformGroup - the uniform group to update
   */
  updateUniformGroup(uniformGroup) {
    this._renderer.uniformGroup.updateUniformGroup(uniformGroup, this._activeProgram, defaultSyncData);
  }
  /**
   * Binds a uniform block to the shader.
   * @param uniformGroup - the uniform group to bind
   * @param name - the name of the uniform block
   * @param index - the index of the uniform block
   */
  bindUniformBlock(uniformGroup, name, index = 0) {
    const bufferSystem = this._renderer.buffer;
    const programData = this._getProgramData(this._activeProgram);
    const isBufferResource = uniformGroup._bufferResource;
    if (!isBufferResource) {
      this._renderer.ubo.updateUniformGroup(uniformGroup);
    }
    const buffer = uniformGroup.buffer;
    const glBuffer = bufferSystem.updateBuffer(buffer);
    const boundLocation = bufferSystem.freeLocationForBufferBase(glBuffer);
    if (isBufferResource) {
      const { offset, size } = uniformGroup;
      if (offset === 0 && size === buffer.data.byteLength) {
        bufferSystem.bindBufferBase(glBuffer, boundLocation);
      } else {
        bufferSystem.bindBufferRange(glBuffer, boundLocation, offset);
      }
    } else if (bufferSystem.getLastBindBaseLocation(glBuffer) !== boundLocation) {
      bufferSystem.bindBufferBase(glBuffer, boundLocation);
    }
    const uniformBlockIndex = this._activeProgram._uniformBlockData[name].index;
    if (programData.uniformBlockBindings[index] === boundLocation) return;
    programData.uniformBlockBindings[index] = boundLocation;
    this._renderer.gl.uniformBlockBinding(programData.program, uniformBlockIndex, boundLocation);
  }
  _setProgram(program) {
    if (this._activeProgram === program) return;
    this._activeProgram = program;
    const programData = this._getProgramData(program);
    this._gl.useProgram(programData.program);
  }
  /**
   * @param program - the program to get the data for
   * @internal
   */
  _getProgramData(program) {
    return this._programDataHash[program._key] || this._createProgramData(program);
  }
  _createProgramData(program) {
    const key = program._key;
    this._programDataHash[key] = generateProgram.generateProgram(this._gl, program);
    return this._programDataHash[key];
  }
  destroy() {
    for (const key of Object.keys(this._programDataHash)) {
      this._programDataHash[key].destroy();
    }
    this._programDataHash = null;
    this._shaderSyncFunctions = null;
    this._activeProgram = null;
    this._renderer = null;
    this._gl = null;
  }
  /**
   * Creates a function that can be executed that will sync the shader as efficiently as possible.
   * Overridden by the unsafe eval package if you don't want eval used in your project.
   * @param shader - the shader to generate the sync function for
   * @param shaderSystem - the shader system to use
   * @returns - the generated sync function
   * @ignore
   */
  _generateShaderSync(shader, shaderSystem) {
    return GenerateShaderSyncCode.generateShaderSyncCode(shader, shaderSystem);
  }
  resetState() {
    this._activeProgram = null;
  }
}
/** @ignore */
GlShaderSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "shader"
};

exports.GlShaderSystem = GlShaderSystem;
//# sourceMappingURL=GlShaderSystem.js.map
