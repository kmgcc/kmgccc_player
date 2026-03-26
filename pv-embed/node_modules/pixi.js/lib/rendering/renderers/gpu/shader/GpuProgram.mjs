import { createIdFromString } from '../../shared/utils/createIdFromString.mjs';
import { extractAttributesFromGpuProgram } from './utils/extractAttributesFromGpuProgram.mjs';
import { extractStructAndGroups } from './utils/extractStructAndGroups.mjs';
import { generateGpuLayoutGroups } from './utils/generateGpuLayoutGroups.mjs';
import { generateLayoutHash } from './utils/generateLayoutHash.mjs';
import { removeStructAndGroupDuplicates } from './utils/removeStructAndGroupDuplicates.mjs';

"use strict";
const programCache = /* @__PURE__ */ Object.create(null);
class GpuProgram {
  /**
   * Create a new GpuProgram
   * @param options - The options for the gpu program
   */
  constructor(options) {
    /** @internal */
    this._layoutKey = 0;
    /** @internal */
    this._attributeLocationsKey = 0;
    const { fragment, vertex, layout, gpuLayout, name } = options;
    this.name = name;
    this.fragment = fragment;
    this.vertex = vertex;
    if (fragment.source === vertex.source) {
      const structsAndGroups = extractStructAndGroups(fragment.source);
      this.structsAndGroups = structsAndGroups;
    } else {
      const vertexStructsAndGroups = extractStructAndGroups(vertex.source);
      const fragmentStructsAndGroups = extractStructAndGroups(fragment.source);
      this.structsAndGroups = removeStructAndGroupDuplicates(vertexStructsAndGroups, fragmentStructsAndGroups);
    }
    this.layout = layout ?? generateLayoutHash(this.structsAndGroups);
    this.gpuLayout = gpuLayout ?? generateGpuLayoutGroups(this.structsAndGroups);
    this.autoAssignGlobalUniforms = !!(this.layout[0]?.globalUniforms !== void 0);
    this.autoAssignLocalUniforms = !!(this.layout[1]?.localUniforms !== void 0);
    this._generateProgramKey();
  }
  // TODO maker this pure
  _generateProgramKey() {
    const { vertex, fragment } = this;
    const bigKey = vertex.source + fragment.source + vertex.entryPoint + fragment.entryPoint;
    this._layoutKey = createIdFromString(bigKey, "program");
  }
  get attributeData() {
    this._attributeData ?? (this._attributeData = extractAttributesFromGpuProgram(this.vertex));
    return this._attributeData;
  }
  /** destroys the program */
  destroy() {
    this.gpuLayout = null;
    this.layout = null;
    this.structsAndGroups = null;
    this.fragment = null;
    this.vertex = null;
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
    const key = `${options.vertex.source}:${options.fragment.source}:${options.fragment.entryPoint}:${options.vertex.entryPoint}`;
    if (!programCache[key]) {
      programCache[key] = new GpuProgram(options);
      programCache[key]._cacheKey = key;
    }
    return programCache[key];
  }
}

export { GpuProgram };
//# sourceMappingURL=GpuProgram.mjs.map
