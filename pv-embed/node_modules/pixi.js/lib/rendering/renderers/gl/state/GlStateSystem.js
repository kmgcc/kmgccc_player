'use strict';

var Extensions = require('../../../../extensions/Extensions.js');
var State = require('../../shared/state/State.js');
var mapWebGLBlendModesToPixi = require('./mapWebGLBlendModesToPixi.js');

"use strict";
const BLEND = 0;
const OFFSET = 1;
const CULLING = 2;
const DEPTH_TEST = 3;
const WINDING = 4;
const DEPTH_MASK = 5;
const _GlStateSystem = class _GlStateSystem {
  constructor(renderer) {
    /**
     * Whether to invert the front face when rendering
     * This is used for render textures where the Y-coordinate is flipped
     * @default false
     */
    this._invertFrontFace = false;
    this.gl = null;
    this.stateId = 0;
    this.polygonOffset = 0;
    this.blendMode = "none";
    this._blendEq = false;
    this.map = [];
    this.map[BLEND] = this.setBlend;
    this.map[OFFSET] = this.setOffset;
    this.map[CULLING] = this.setCullFace;
    this.map[DEPTH_TEST] = this.setDepthTest;
    this.map[WINDING] = this.setFrontFace;
    this.map[DEPTH_MASK] = this.setDepthMask;
    this.checks = [];
    this.defaultState = State.State.for2d();
    renderer.renderTarget.onRenderTargetChange.add(this);
  }
  onRenderTargetChange(renderTarget) {
    this._invertFrontFace = !renderTarget.isRoot;
    if (this._cullFace) {
      this.setFrontFace(this._frontFace);
    } else {
      this._frontFaceDirty = true;
    }
  }
  contextChange(gl) {
    this.gl = gl;
    this.blendModesMap = mapWebGLBlendModesToPixi.mapWebGLBlendModesToPixi(gl);
    this.resetState();
  }
  /**
   * Sets the current state
   * @param {*} state - The state to set.
   */
  set(state) {
    state || (state = this.defaultState);
    if (this.stateId !== state.data) {
      let diff = this.stateId ^ state.data;
      let i = 0;
      while (diff) {
        if (diff & 1) {
          this.map[i].call(this, !!(state.data & 1 << i));
        }
        diff >>= 1;
        i++;
      }
      this.stateId = state.data;
    }
    for (let i = 0; i < this.checks.length; i++) {
      this.checks[i](this, state);
    }
  }
  /**
   * Sets the state, when previous state is unknown.
   * @param {*} state - The state to set
   */
  forceState(state) {
    state || (state = this.defaultState);
    for (let i = 0; i < this.map.length; i++) {
      this.map[i].call(this, !!(state.data & 1 << i));
    }
    for (let i = 0; i < this.checks.length; i++) {
      this.checks[i](this, state);
    }
    this.stateId = state.data;
  }
  /**
   * Sets whether to enable or disable blending.
   * @param value - Turn on or off WebGl blending.
   */
  setBlend(value) {
    this._updateCheck(_GlStateSystem._checkBlendMode, value);
    this.gl[value ? "enable" : "disable"](this.gl.BLEND);
  }
  /**
   * Sets whether to enable or disable polygon offset fill.
   * @param value - Turn on or off webgl polygon offset testing.
   */
  setOffset(value) {
    this._updateCheck(_GlStateSystem._checkPolygonOffset, value);
    this.gl[value ? "enable" : "disable"](this.gl.POLYGON_OFFSET_FILL);
  }
  /**
   * Sets whether to enable or disable depth test.
   * @param value - Turn on or off webgl depth testing.
   */
  setDepthTest(value) {
    this.gl[value ? "enable" : "disable"](this.gl.DEPTH_TEST);
  }
  /**
   * Sets whether to enable or disable depth mask.
   * @param value - Turn on or off webgl depth mask.
   */
  setDepthMask(value) {
    this.gl.depthMask(value);
  }
  /**
   * Sets whether to enable or disable cull face.
   * @param {boolean} value - Turn on or off webgl cull face.
   */
  setCullFace(value) {
    this._cullFace = value;
    this.gl[value ? "enable" : "disable"](this.gl.CULL_FACE);
    if (this._cullFace && this._frontFaceDirty) {
      this.setFrontFace(this._frontFace);
    }
  }
  /**
   * Sets the gl front face.
   * @param {boolean} value - true is clockwise and false is counter-clockwise
   */
  setFrontFace(value) {
    this._frontFace = value;
    this._frontFaceDirty = false;
    const faceMode = this._invertFrontFace ? !value : value;
    if (this._glFrontFace !== faceMode) {
      this._glFrontFace = faceMode;
      this.gl.frontFace(this.gl[faceMode ? "CW" : "CCW"]);
    }
  }
  /**
   * Sets the blend mode.
   * @param {number} value - The blend mode to set to.
   */
  setBlendMode(value) {
    if (!this.blendModesMap[value]) {
      value = "normal";
    }
    if (value === this.blendMode) {
      return;
    }
    this.blendMode = value;
    const mode = this.blendModesMap[value];
    const gl = this.gl;
    if (mode.length === 2) {
      gl.blendFunc(mode[0], mode[1]);
    } else {
      gl.blendFuncSeparate(mode[0], mode[1], mode[2], mode[3]);
    }
    if (mode.length === 6) {
      this._blendEq = true;
      gl.blendEquationSeparate(mode[4], mode[5]);
    } else if (this._blendEq) {
      this._blendEq = false;
      gl.blendEquationSeparate(gl.FUNC_ADD, gl.FUNC_ADD);
    }
  }
  /**
   * Sets the polygon offset.
   * @param {number} value - the polygon offset
   * @param {number} scale - the polygon offset scale
   */
  setPolygonOffset(value, scale) {
    this.gl.polygonOffset(value, scale);
  }
  /** Resets all the logic and disables the VAOs. */
  resetState() {
    this._glFrontFace = false;
    this._frontFace = false;
    this._cullFace = false;
    this._frontFaceDirty = false;
    this._invertFrontFace = false;
    this.gl.frontFace(this.gl.CCW);
    this.gl.pixelStorei(this.gl.UNPACK_FLIP_Y_WEBGL, false);
    this.forceState(this.defaultState);
    this._blendEq = true;
    this.blendMode = "";
    this.setBlendMode("normal");
  }
  /**
   * Checks to see which updates should be checked based on which settings have been activated.
   *
   * For example, if blend is enabled then we should check the blend modes each time the state is changed
   * or if polygon fill is activated then we need to check if the polygon offset changes.
   * The idea is that we only check what we have too.
   * @param func - the checking function to add or remove
   * @param value - should the check function be added or removed.
   */
  _updateCheck(func, value) {
    const index = this.checks.indexOf(func);
    if (value && index === -1) {
      this.checks.push(func);
    } else if (!value && index !== -1) {
      this.checks.splice(index, 1);
    }
  }
  /**
   * A private little wrapper function that we call to check the blend mode.
   * @param system - the System to perform the state check on
   * @param state - the state that the blendMode will pulled from
   */
  static _checkBlendMode(system, state) {
    system.setBlendMode(state.blendMode);
  }
  /**
   * A private little wrapper function that we call to check the polygon offset.
   * @param system - the System to perform the state check on
   * @param state - the state that the blendMode will pulled from
   */
  static _checkPolygonOffset(system, state) {
    system.setPolygonOffset(1, state.polygonOffset);
  }
  /** @ignore */
  destroy() {
    this.gl = null;
    this.checks.length = 0;
  }
};
/** @ignore */
_GlStateSystem.extension = {
  type: [
    Extensions.ExtensionType.WebGLSystem
  ],
  name: "state"
};
let GlStateSystem = _GlStateSystem;

exports.GlStateSystem = GlStateSystem;
//# sourceMappingURL=GlStateSystem.js.map
