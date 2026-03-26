import type { BLEND_MODES } from '../../shared/state/const';
/**
 * Builds the Canvas blend mode map for Pixi blend enums.
 * @returns A mapping of Pixi blend modes to canvas composite ops.
 * @internal
 */
export declare function mapCanvasBlendModesToPixi(): Record<BLEND_MODES, GlobalCompositeOperation | null>;
