'use strict';

"use strict";
function executeInstructions(renderGroup, renderer) {
  const instructionSet = renderGroup.instructionSet;
  const instructions = instructionSet.instructions;
  for (let i = 0; i < instructionSet.instructionSize; i++) {
    const instruction = instructions[i];
    renderer[instruction.renderPipeId].execute(instruction);
  }
}

exports.executeInstructions = executeInstructions;
//# sourceMappingURL=executeInstructions.js.map
