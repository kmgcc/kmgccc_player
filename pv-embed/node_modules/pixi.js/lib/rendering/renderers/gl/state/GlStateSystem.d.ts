import { ExtensionType } from '../../../../extensions/Extensions';
import { type RenderTarget } from '../../shared/renderTarget/RenderTarget';
import { State } from '../../shared/state/State';
import { type WebGLRenderer } from '../WebGLRenderer';
import type { BLEND_MODES } from '../../shared/state/const';
import type { System } from '../../shared/system/System';
import type { GlRenderingContext } from '../context/GlRenderingContext';
/**
 * System plugin to the renderer to manage WebGL state machines
 * @category rendering
 * @advanced
 */
export declare class GlStateSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
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
    protected gl: GlRenderingContext;
    protected blendModesMap: Record<BLEND_MODES, number[]>;
    /**
     * Collection of calls
     * @type {Function[]}
     */
    protected readonly map: ((value: boolean) => void)[];
    /**
     * Collection of check calls
     * @type {Function[]}
     */
    protected readonly checks: ((system: this, state: State) => void)[];
    /**
     * Default WebGL State
     * @readonly
     */
    protected defaultState: State;
    /**
     * Whether to invert the front face when rendering
     * This is used for render textures where the Y-coordinate is flipped
     * @default false
     */
    private _invertFrontFace;
    private _glFrontFace;
    private _cullFace;
    private _frontFaceDirty;
    private _frontFace;
    constructor(renderer: WebGLRenderer);
    protected onRenderTargetChange(renderTarget: RenderTarget): void;
    protected contextChange(gl: GlRenderingContext): void;
    /**
     * Sets the current state
     * @param {*} state - The state to set.
     */
    set(state: State): void;
    /**
     * Sets the state, when previous state is unknown.
     * @param {*} state - The state to set
     */
    forceState(state: State): void;
    /**
     * Sets whether to enable or disable blending.
     * @param value - Turn on or off WebGl blending.
     */
    setBlend(value: boolean): void;
    /**
     * Sets whether to enable or disable polygon offset fill.
     * @param value - Turn on or off webgl polygon offset testing.
     */
    setOffset(value: boolean): void;
    /**
     * Sets whether to enable or disable depth test.
     * @param value - Turn on or off webgl depth testing.
     */
    setDepthTest(value: boolean): void;
    /**
     * Sets whether to enable or disable depth mask.
     * @param value - Turn on or off webgl depth mask.
     */
    setDepthMask(value: boolean): void;
    /**
     * Sets whether to enable or disable cull face.
     * @param {boolean} value - Turn on or off webgl cull face.
     */
    setCullFace(value: boolean): void;
    /**
     * Sets the gl front face.
     * @param {boolean} value - true is clockwise and false is counter-clockwise
     */
    setFrontFace(value: boolean): void;
    /**
     * Sets the blend mode.
     * @param {number} value - The blend mode to set to.
     */
    setBlendMode(value: BLEND_MODES): void;
    /**
     * Sets the polygon offset.
     * @param {number} value - the polygon offset
     * @param {number} scale - the polygon offset scale
     */
    setPolygonOffset(value: number, scale: number): void;
    /** Resets all the logic and disables the VAOs. */
    resetState(): void;
    /**
     * Checks to see which updates should be checked based on which settings have been activated.
     *
     * For example, if blend is enabled then we should check the blend modes each time the state is changed
     * or if polygon fill is activated then we need to check if the polygon offset changes.
     * The idea is that we only check what we have too.
     * @param func - the checking function to add or remove
     * @param value - should the check function be added or removed.
     */
    private _updateCheck;
    /**
     * A private little wrapper function that we call to check the blend mode.
     * @param system - the System to perform the state check on
     * @param state - the state that the blendMode will pulled from
     */
    private static _checkBlendMode;
    /**
     * A private little wrapper function that we call to check the polygon offset.
     * @param system - the System to perform the state check on
     * @param state - the state that the blendMode will pulled from
     */
    private static _checkPolygonOffset;
    /** @ignore */
    destroy(): void;
}
