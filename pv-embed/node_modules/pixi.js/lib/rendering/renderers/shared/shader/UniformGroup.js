'use strict';

var uid = require('../../../../utils/data/uid.js');
var createIdFromString = require('../utils/createIdFromString.js');
var types = require('./types.js');
var getDefaultUniformValue = require('./utils/getDefaultUniformValue.js');

"use strict";
const _UniformGroup = class _UniformGroup {
  /**
   * Create a new Uniform group
   * @param uniformStructures - The structures of the uniform group
   * @param options - The optional parameters of this uniform group
   */
  constructor(uniformStructures, options) {
    /**
     * used internally to know if a uniform group was used in the last render pass
     * @internal
     */
    this._touched = 0;
    /** a unique id for this uniform group used through the renderer */
    this.uid = uid.uid("uniform");
    /**
     * a resource type, used to identify how to handle it when its in a bind group / shader resource
     * @internal
     */
    this._resourceType = "uniformGroup";
    /**
     * the resource id used internally by the renderer to build bind group keys
     * @internal
     */
    this._resourceId = uid.uid("resource");
    /** used ito identify if this is a uniform group */
    this.isUniformGroup = true;
    /**
     * used to flag if this Uniform groups data is different from what it has stored in its buffer / on the GPU
     * @internal
     */
    this._dirtyId = 0;
    // implementing the interface - UniformGroup are not destroyed
    this.destroyed = false;
    options = { ..._UniformGroup.defaultOptions, ...options };
    this.uniformStructures = uniformStructures;
    const uniforms = {};
    for (const i in uniformStructures) {
      const uniformData = uniformStructures[i];
      uniformData.name = i;
      uniformData.size = uniformData.size ?? 1;
      if (!types.UNIFORM_TYPES_MAP[uniformData.type]) {
        const arrayMatch = uniformData.type.match(/^array<(\w+(?:<\w+>)?),\s*(\d+)>$/);
        if (arrayMatch) {
          const [, innerType, size] = arrayMatch;
          throw new Error(
            `Uniform type ${uniformData.type} is not supported. Use type: '${innerType}', size: ${size} instead.`
          );
        }
        throw new Error(`Uniform type ${uniformData.type} is not supported. Supported uniform types are: ${types.UNIFORM_TYPES_VALUES.join(", ")}`);
      }
      uniformData.value ?? (uniformData.value = getDefaultUniformValue.getDefaultUniformValue(uniformData.type, uniformData.size));
      uniforms[i] = uniformData.value;
    }
    this.uniforms = uniforms;
    this._dirtyId = 1;
    this.ubo = options.ubo;
    this.isStatic = options.isStatic;
    this._signature = createIdFromString.createIdFromString(Object.keys(uniforms).map(
      (i) => `${i}-${uniformStructures[i].type}`
    ).join("-"), "uniform-group");
  }
  /** Call this if you want the uniform groups data to be uploaded to the GPU only useful if `isStatic` is true. */
  update() {
    this._dirtyId++;
  }
};
/** The default options used by the uniform group. */
_UniformGroup.defaultOptions = {
  /** if true the UniformGroup is handled as an Uniform buffer object. */
  ubo: false,
  /** if true, then you are responsible for when the data is uploaded to the GPU by calling `update()` */
  isStatic: false
};
let UniformGroup = _UniformGroup;

exports.UniformGroup = UniformGroup;
//# sourceMappingURL=UniformGroup.js.map
