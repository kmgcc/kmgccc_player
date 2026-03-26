"use strict";
function executeInstructions(renderGroup, renderer) {
  const instructionSet = renderGroup.instructionSet;
  const instructions = instructionSet.instructions;
  for (let i = 0; i < instructionSet.instructionSize; i++) {
    const instruction = instructions[i];
    renderer[instruction.renderPipeId].execute(instruction);
  }
}

export { executeInstructions };
//# sourceMappingURL=executeInstructions.mjs.map
