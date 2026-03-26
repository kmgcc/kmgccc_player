'use strict';

var uid = require('../../../../utils/data/uid.js');

"use strict";
class InstructionSet {
  constructor() {
    /** a unique id for this instruction set used through the renderer */
    this.uid = uid.uid("instructionSet");
    /** the array of instructions */
    this.instructions = [];
    /** the actual size of the array (any instructions passed this should be ignored) */
    this.instructionSize = 0;
    this.renderables = [];
    /** used by the garbage collector to track when the instruction set was last used */
    this.gcTick = 0;
  }
  /** reset the instruction set so it can be reused set size back to 0 */
  reset() {
    this.instructionSize = 0;
  }
  /**
   * Destroy the instruction set, clearing the instructions and renderables.
   * @internal
   */
  destroy() {
    this.instructions.length = 0;
    this.renderables.length = 0;
    this.renderPipes = null;
    this.gcTick = 0;
  }
  /**
   * Add an instruction to the set
   * @param instruction - add an instruction to the set
   */
  add(instruction) {
    this.instructions[this.instructionSize++] = instruction;
  }
  /**
   * Log the instructions to the console (for debugging)
   * @internal
   */
  log() {
    this.instructions.length = this.instructionSize;
    console.table(this.instructions, ["type", "action"]);
  }
}

exports.InstructionSet = InstructionSet;
//# sourceMappingURL=InstructionSet.js.map
