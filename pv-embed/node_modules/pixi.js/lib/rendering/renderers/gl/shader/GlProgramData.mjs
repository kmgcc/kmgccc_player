"use strict";
class IGLUniformData {
}
class GlProgramData {
  /**
   * Makes a new Pixi program.
   * @param program - webgl program
   * @param uniformData - uniforms
   */
  constructor(program, uniformData) {
    this.program = program;
    this.uniformData = uniformData;
    this.uniformGroups = {};
    this.uniformDirtyGroups = {};
    this.uniformBlockBindings = {};
  }
  /** Destroys this program. */
  destroy() {
    this.uniformData = null;
    this.uniformGroups = null;
    this.uniformDirtyGroups = null;
    this.uniformBlockBindings = null;
    this.program = null;
  }
}

export { GlProgramData, IGLUniformData };
//# sourceMappingURL=GlProgramData.mjs.map
