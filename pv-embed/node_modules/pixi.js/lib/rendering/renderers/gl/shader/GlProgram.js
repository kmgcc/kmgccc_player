'use strict';

var createIdFromString = require('../../shared/utils/createIdFromString.js');
var getMaxFragmentPrecision = require('./program/getMaxFragmentPrecision.js');
var addProgramDefines = require('./program/preprocessors/addProgramDefines.js');
var ensurePrecision = require('./program/preprocessors/ensurePrecision.js');
var insertVersion = require('./program/preprocessors/insertVersion.js');
var setProgramName = require('./program/preprocessors/setProgramName.js');
var stripVersion = require('./program/preprocessors/stripVersion.js');

"use strict";
const processes = {
  // strips any version headers..
  stripVersion: stripVersion.stripVersion,
  // adds precision string if not already present
  ensurePrecision: ensurePrecision.ensurePrecision,
  // add some defines if WebGL1 to make it more compatible with WebGL2 shaders
  addProgramDefines: addProgramDefines.addProgramDefines,
  // add the program name to the shader
  setProgramName: setProgramName.setProgramName,
  // add the version string to the shader header
  insertVersion: insertVersion.insertVersion
};
const programCache = /* @__PURE__ */ Object.create(null);
const _GlProgram = class _GlProgram {
  /**
   * Creates a shiny new GlProgram. Used by WebGL renderer.
   * @param options - The options for the program.
   */
  constructor(options) {
    options = { ..._GlProgram.defaultOptions, ...options };
    const isES300 = options.fragment.indexOf("#version 300 es") !== -1;
    const preprocessorOptions = {
      stripVersion: isES300,
      ensurePrecision: {
        requestedFragmentPrecision: options.preferredFragmentPrecision,
        requestedVertexPrecision: options.preferredVertexPrecision,
        maxSupportedVertexPrecision: "highp",
        maxSupportedFragmentPrecision: getMaxFragmentPrecision.getMaxFragmentPrecision()
      },
      setProgramName: {
        name: options.name
      },
      addProgramDefines: isES300,
      insertVersion: isES300
    };
    let fragment = options.fragment;
    let vertex = options.vertex;
    Object.keys(processes).forEach((processKey) => {
      const processOptions = preprocessorOptions[processKey];
      fragment = processes[processKey](fragment, processOptions, true);
      vertex = processes[processKey](vertex, processOptions, false);
    });
    this.fragment = fragment;
    this.vertex = vertex;
    this.transformFeedbackVaryings = options.transformFeedbackVaryings;
    this._key = createIdFromString.createIdFromString(`${this.vertex}:${this.fragment}`, "gl-program");
  }
  /** destroys the program */
  destroy() {
    this.fragment = null;
    this.vertex = null;
    this._attributeData = null;
    this._uniformData = null;
    this._uniformBlockData = null;
    this.transformFeedbackVaryings = null;
    programCache[this._cacheKey] = null;
  }
  /**
   * Helper function that creates a program for a given source.
   * It will check the program cache if the program has already been created.
   * If it has that one will be returned, if not a new one will be created and cached.
   * @param options - The options for the program.
   * @returns A program using the same source
   */
  static from(options) {
    const key = `${options.vertex}:${options.fragment}`;
    if (!programCache[key]) {
      programCache[key] = new _GlProgram(options);
      programCache[key]._cacheKey = key;
    }
    return programCache[key];
  }
};
/** The default options used by the program. */
_GlProgram.defaultOptions = {
  preferredVertexPrecision: "highp",
  preferredFragmentPrecision: "mediump"
};
let GlProgram = _GlProgram;

exports.GlProgram = GlProgram;
//# sourceMappingURL=GlProgram.js.map
