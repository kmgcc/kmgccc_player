import { ExtensionType } from '../../../../extensions/Extensions';
import { State } from '../../shared/state/State';
import type { BLEND_MODES } from '../../shared/state/const';
import type { System } from '../../shared/system/System';
import type { GPU } from '../GpuDeviceSystem';
/**
 * System plugin to the renderer to manage WebGL state machines.
 * @category rendering
 * @advanced
 */
export declare class GpuStateSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "state";
    };
    /**
     * State ID
     * @readonly
     */
    stateId: number;
    /**
     * Polygon offset
     * @readonly
     */
    polygonOffset: number;
    /**
     * Blend mode
     * @default 'none'
     * @readonly
     */
    blendMode: BLEND_MODES;
    /** Whether current blend equation is different */
    protected _blendEq: boolean;
    /**
     * GL context
     * @type {WebGLRenderingContext}
     * @readonly
     */
    protected gpu: GPU;
    /**
     * Default WebGL State
     * @readonly
     */
    protected defaultState: State;
    constructor();
    protected contextChange(gpu: GPU): void;
    /**
     * Gets the blend mode data for the current state
     * @param state - The state to get the blend mode from
     * @param count - The number of color targets to create
     */
    getColorTargets(state: State, count: number): GPUColorTargetState[];
    destroy(): void;
}
