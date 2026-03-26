'use strict';

"use strict";
function checkForNestedPattern(subpathsWithArea) {
  if (subpathsWithArea.length <= 2) {
    return true;
  }
  const areas = subpathsWithArea.map((s) => s.area).sort((a, b) => b - a);
  const [largestArea, secondArea] = areas;
  const smallestArea = areas[areas.length - 1];
  const largestToSecondRatio = largestArea / secondArea;
  const secondToSmallestRatio = secondArea / smallestArea;
  if (largestToSecondRatio > 3 && secondToSmallestRatio < 2) {
    return false;
  }
  return true;
}
function getFillInstructionData(context, index = 0) {
  const instruction = context.instructions[index];
  if (!instruction || instruction.action !== "fill") {
    throw new Error(`Expected fill instruction at index ${index}, got ${instruction?.action || "undefined"}`);
  }
  return instruction.data;
}

exports.checkForNestedPattern = checkForNestedPattern;
exports.getFillInstructionData = getFillInstructionData;
//# sourceMappingURL=fillOperations.js.map
