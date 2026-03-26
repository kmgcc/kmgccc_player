import { STENCIL_MODES } from '../../shared/state/const.mjs';

"use strict";
const GpuStencilModesToPixi = [];
GpuStencilModesToPixi[STENCIL_MODES.NONE] = void 0;
GpuStencilModesToPixi[STENCIL_MODES.DISABLED] = {
  stencilWriteMask: 0,
  stencilReadMask: 0
};
GpuStencilModesToPixi[STENCIL_MODES.RENDERING_MASK_ADD] = {
  stencilFront: {
    compare: "equal",
    passOp: "increment-clamp"
  },
  stencilBack: {
    compare: "equal",
    passOp: "increment-clamp"
  }
};
GpuStencilModesToPixi[STENCIL_MODES.RENDERING_MASK_REMOVE] = {
  stencilFront: {
    compare: "equal",
    passOp: "decrement-clamp"
  },
  stencilBack: {
    compare: "equal",
    passOp: "decrement-clamp"
  }
};
GpuStencilModesToPixi[STENCIL_MODES.MASK_ACTIVE] = {
  stencilWriteMask: 0,
  stencilFront: {
    compare: "equal",
    passOp: "keep"
  },
  stencilBack: {
    compare: "equal",
    passOp: "keep"
  }
};
GpuStencilModesToPixi[STENCIL_MODES.INVERSE_MASK_ACTIVE] = {
  stencilWriteMask: 0,
  stencilFront: {
    compare: "not-equal",
    passOp: "keep"
  },
  stencilBack: {
    compare: "not-equal",
    passOp: "keep"
  }
};

export { GpuStencilModesToPixi };
//# sourceMappingURL=GpuStencilModesToPixi.mjs.map
