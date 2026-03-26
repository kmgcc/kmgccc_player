'use strict';

var _const = require('../../../shared/shader/const.js');

"use strict";
function generateGpuLayoutGroups({ groups }) {
  const layout = [];
  for (let i = 0; i < groups.length; i++) {
    const group = groups[i];
    if (!layout[group.group]) {
      layout[group.group] = [];
    }
    if (group.isUniform) {
      layout[group.group].push({
        binding: group.binding,
        visibility: _const.ShaderStage.VERTEX | _const.ShaderStage.FRAGMENT,
        buffer: {
          type: "uniform"
        }
      });
    } else if (group.type === "sampler") {
      layout[group.group].push({
        binding: group.binding,
        visibility: _const.ShaderStage.FRAGMENT,
        sampler: {
          type: "filtering"
        }
      });
    } else if (group.type === "texture_2d" || group.type.startsWith("texture_2d<")) {
      layout[group.group].push({
        binding: group.binding,
        visibility: _const.ShaderStage.FRAGMENT,
        texture: {
          sampleType: "float",
          viewDimension: "2d",
          multisampled: false
        }
      });
    } else if (group.type === "texture_2d_array" || group.type.startsWith("texture_2d_array<")) {
      layout[group.group].push({
        binding: group.binding,
        visibility: _const.ShaderStage.FRAGMENT,
        texture: {
          sampleType: "float",
          viewDimension: "2d-array",
          multisampled: false
        }
      });
    } else if (group.type === "texture_cube" || group.type.startsWith("texture_cube<")) {
      layout[group.group].push({
        binding: group.binding,
        visibility: _const.ShaderStage.FRAGMENT,
        texture: {
          sampleType: "float",
          viewDimension: "cube",
          multisampled: false
        }
      });
    }
  }
  for (let i = 0; i < layout.length; i++) {
    layout[i] || (layout[i] = []);
  }
  return layout;
}

exports.generateGpuLayoutGroups = generateGpuLayoutGroups;
//# sourceMappingURL=generateGpuLayoutGroups.js.map
