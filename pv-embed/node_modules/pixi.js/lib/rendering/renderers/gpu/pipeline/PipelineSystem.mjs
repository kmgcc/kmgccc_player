import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { warn } from '../../../../utils/logging/warn.mjs';
import { ensureAttributes } from '../../gl/shader/program/ensureAttributes.mjs';
import { STENCIL_MODES } from '../../shared/state/const.mjs';
import { createIdFromString } from '../../shared/utils/createIdFromString.mjs';
import { GpuStencilModesToPixi } from '../state/GpuStencilModesToPixi.mjs';

"use strict";
const topologyStringToId = {
  "point-list": 0,
  "line-list": 1,
  "line-strip": 2,
  "triangle-list": 3,
  "triangle-strip": 4
};
function getGraphicsStateKey(geometryLayout, shaderKey, state, blendMode, topology) {
  return geometryLayout << 24 | shaderKey << 16 | state << 10 | blendMode << 5 | topology;
}
function getGlobalStateKey(stencilStateId, multiSampleCount, colorMask, renderTarget, colorTargetCount) {
  return colorMask << 8 | stencilStateId << 5 | renderTarget << 3 | colorTargetCount << 1 | multiSampleCount;
}
class PipelineSystem {
  constructor(renderer) {
    this._moduleCache = /* @__PURE__ */ Object.create(null);
    this._bufferLayoutsCache = /* @__PURE__ */ Object.create(null);
    this._bindingNamesCache = /* @__PURE__ */ Object.create(null);
    this._pipeCache = /* @__PURE__ */ Object.create(null);
    this._pipeStateCaches = /* @__PURE__ */ Object.create(null);
    this._colorMask = 15;
    this._multisampleCount = 1;
    this._colorTargetCount = 1;
    this._renderer = renderer;
  }
  contextChange(gpu) {
    this._gpu = gpu;
    this.setStencilMode(STENCIL_MODES.DISABLED);
    this._updatePipeHash();
  }
  setMultisampleCount(multisampleCount) {
    if (this._multisampleCount === multisampleCount) return;
    this._multisampleCount = multisampleCount;
    this._updatePipeHash();
  }
  setRenderTarget(renderTarget) {
    this._multisampleCount = renderTarget.msaaSamples;
    this._depthStencilAttachment = renderTarget.descriptor.depthStencilAttachment ? 1 : 0;
    this._colorTargetCount = renderTarget.colorTargetCount;
    this._updatePipeHash();
  }
  setColorMask(colorMask) {
    if (this._colorMask === colorMask) return;
    this._colorMask = colorMask;
    this._updatePipeHash();
  }
  setStencilMode(stencilMode) {
    if (this._stencilMode === stencilMode) return;
    this._stencilMode = stencilMode;
    this._stencilState = GpuStencilModesToPixi[stencilMode];
    this._updatePipeHash();
  }
  setPipeline(geometry, program, state, passEncoder) {
    const pipeline = this.getPipeline(geometry, program, state);
    passEncoder.setPipeline(pipeline);
  }
  getPipeline(geometry, program, state, topology) {
    if (!geometry._layoutKey) {
      ensureAttributes(geometry, program.attributeData);
      this._generateBufferKey(geometry);
    }
    topology || (topology = geometry.topology);
    const key = getGraphicsStateKey(
      geometry._layoutKey,
      program._layoutKey,
      state.data,
      state._blendModeId,
      topologyStringToId[topology]
    );
    if (this._pipeCache[key]) return this._pipeCache[key];
    this._pipeCache[key] = this._createPipeline(geometry, program, state, topology);
    return this._pipeCache[key];
  }
  _createPipeline(geometry, program, state, topology) {
    const device = this._gpu.device;
    const buffers = this._createVertexBufferLayouts(geometry, program);
    const blendModes = this._renderer.state.getColorTargets(state, this._colorTargetCount);
    const writeMask = this._stencilMode === STENCIL_MODES.RENDERING_MASK_ADD ? 0 : this._colorMask;
    for (let i = 0; i < blendModes.length; i++) {
      blendModes[i].writeMask = writeMask;
    }
    const layout = this._renderer.shader.getProgramData(program).pipeline;
    const descriptor = {
      // TODO later check if its helpful to create..
      // layout,
      vertex: {
        module: this._getModule(program.vertex.source),
        entryPoint: program.vertex.entryPoint,
        // geometry..
        buffers
      },
      fragment: {
        module: this._getModule(program.fragment.source),
        entryPoint: program.fragment.entryPoint,
        targets: blendModes
      },
      primitive: {
        topology,
        cullMode: state.cullMode
      },
      layout,
      multisample: {
        count: this._multisampleCount
      },
      // depthStencil,
      label: `PIXI Pipeline`
    };
    if (this._depthStencilAttachment) {
      descriptor.depthStencil = {
        ...this._stencilState,
        format: "depth24plus-stencil8",
        depthWriteEnabled: state.depthTest,
        depthCompare: state.depthTest ? "less" : "always"
      };
    }
    const pipeline = device.createRenderPipeline(descriptor);
    return pipeline;
  }
  _getModule(code) {
    return this._moduleCache[code] || this._createModule(code);
  }
  _createModule(code) {
    const device = this._gpu.device;
    this._moduleCache[code] = device.createShaderModule({
      code
    });
    return this._moduleCache[code];
  }
  _generateBufferKey(geometry) {
    const keyGen = [];
    let index = 0;
    const attributeKeys = Object.keys(geometry.attributes).sort();
    for (let i = 0; i < attributeKeys.length; i++) {
      const attribute = geometry.attributes[attributeKeys[i]];
      keyGen[index++] = attribute.offset;
      keyGen[index++] = attribute.format;
      keyGen[index++] = attribute.stride;
      keyGen[index++] = attribute.instance;
    }
    const stringKey = keyGen.join("|");
    geometry._layoutKey = createIdFromString(stringKey, "geometry");
    return geometry._layoutKey;
  }
  _generateAttributeLocationsKey(program) {
    const keyGen = [];
    let index = 0;
    const attributeKeys = Object.keys(program.attributeData).sort();
    for (let i = 0; i < attributeKeys.length; i++) {
      const attribute = program.attributeData[attributeKeys[i]];
      keyGen[index++] = attribute.location;
    }
    const stringKey = keyGen.join("|");
    program._attributeLocationsKey = createIdFromString(stringKey, "programAttributes");
    return program._attributeLocationsKey;
  }
  /**
   * Returns a hash of buffer names mapped to bind locations.
   * This is used to bind the correct buffer to the correct location in the shader.
   * @param geometry - The geometry where to get the buffer names
   * @param program - The program where to get the buffer names
   * @returns An object of buffer names mapped to the bind location.
   */
  getBufferNamesToBind(geometry, program) {
    const key = geometry._layoutKey << 16 | program._attributeLocationsKey;
    if (this._bindingNamesCache[key]) return this._bindingNamesCache[key];
    const data = this._createVertexBufferLayouts(geometry, program);
    const bufferNamesToBind = /* @__PURE__ */ Object.create(null);
    const attributeData = program.attributeData;
    for (let i = 0; i < data.length; i++) {
      const attributes = Object.values(data[i].attributes);
      const shaderLocation = attributes[0].shaderLocation;
      for (const j in attributeData) {
        if (attributeData[j].location === shaderLocation) {
          bufferNamesToBind[i] = j;
          break;
        }
      }
    }
    this._bindingNamesCache[key] = bufferNamesToBind;
    return bufferNamesToBind;
  }
  _createVertexBufferLayouts(geometry, program) {
    if (!program._attributeLocationsKey) this._generateAttributeLocationsKey(program);
    const key = geometry._layoutKey << 16 | program._attributeLocationsKey;
    if (this._bufferLayoutsCache[key]) {
      return this._bufferLayoutsCache[key];
    }
    const vertexBuffersLayout = [];
    geometry.buffers.forEach((buffer) => {
      const bufferEntry = {
        arrayStride: 0,
        stepMode: "vertex",
        attributes: []
      };
      const bufferEntryAttributes = bufferEntry.attributes;
      for (const i in program.attributeData) {
        const attribute = geometry.attributes[i];
        if ((attribute.divisor ?? 1) !== 1) {
          warn(`Attribute ${i} has an invalid divisor value of '${attribute.divisor}'. WebGPU only supports a divisor value of 1`);
        }
        if (attribute.buffer === buffer) {
          bufferEntry.arrayStride = attribute.stride;
          bufferEntry.stepMode = attribute.instance ? "instance" : "vertex";
          bufferEntryAttributes.push({
            shaderLocation: program.attributeData[i].location,
            offset: attribute.offset,
            format: attribute.format
          });
        }
      }
      if (bufferEntryAttributes.length) {
        vertexBuffersLayout.push(bufferEntry);
      }
    });
    this._bufferLayoutsCache[key] = vertexBuffersLayout;
    return vertexBuffersLayout;
  }
  _updatePipeHash() {
    const key = getGlobalStateKey(
      this._stencilMode,
      this._multisampleCount,
      this._colorMask,
      this._depthStencilAttachment,
      this._colorTargetCount
    );
    if (!this._pipeStateCaches[key]) {
      this._pipeStateCaches[key] = /* @__PURE__ */ Object.create(null);
    }
    this._pipeCache = this._pipeStateCaches[key];
  }
  destroy() {
    this._renderer = null;
    this._bufferLayoutsCache = null;
  }
}
/** @ignore */
PipelineSystem.extension = {
  type: [ExtensionType.WebGPUSystem],
  name: "pipeline"
};

export { PipelineSystem };
//# sourceMappingURL=PipelineSystem.mjs.map
