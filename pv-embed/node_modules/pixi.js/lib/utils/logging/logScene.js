'use strict';

var Sprite = require('../../scene/sprite/Sprite.js');

"use strict";
const colors = [
  "#000080",
  // Navy Blue
  "#228B22",
  // Forest Green
  "#8B0000",
  // Dark Red
  "#4169E1",
  // Royal Blue
  "#008080",
  // Teal
  "#800000",
  // Maroon
  "#9400D3",
  // Dark Violet
  "#FF8C00",
  // Dark Orange
  "#556B2F",
  // Olive Green
  "#8B008B"
  // Dark Magenta
];
let colorTick = 0;
function logScene(container, depth = 0, data = { color: "#000000" }) {
  if (container.renderGroup) {
    data.color = colors[colorTick++];
  }
  let spaces = "";
  for (let i = 0; i < depth; i++) {
    spaces += "    ";
  }
  let label = container.label;
  if (!label && container instanceof Sprite.Sprite) {
    label = `sprite:${container.texture.label}`;
  }
  let output = `%c ${spaces}|- ${label} (worldX:${container.worldTransform.tx}, relativeRenderX:${container.relativeGroupTransform.tx}, renderX:${container.groupTransform.tx}, localX:${container.x})`;
  if (container.renderGroup) {
    output += " (RenderGroup)";
  }
  if (container.filters) {
    output += "(*filters)";
  }
  console.log(output, `color:${data.color}; font-weight:bold;`);
  depth++;
  for (let i = 0; i < container.children.length; i++) {
    const child = container.children[i];
    logScene(child, depth, { ...data });
  }
}
function logRenderGroupScene(renderGroup, depth = 0, data = { index: 0, color: "#000000" }) {
  let spaces = "";
  for (let i = 0; i < depth; i++) {
    spaces += "    ";
  }
  const output = `%c ${spaces}- ${data.index}: ${renderGroup.root.label} worldX:${renderGroup.worldTransform.tx}`;
  console.log(output, `color:${data.color}; font-weight:bold;`);
  depth++;
  for (let i = 0; i < renderGroup.renderGroupChildren.length; i++) {
    const child = renderGroup.renderGroupChildren[i];
    logRenderGroupScene(child, depth, { ...data, index: i });
  }
}

exports.logRenderGroupScene = logRenderGroupScene;
exports.logScene = logScene;
//# sourceMappingURL=logScene.js.map
