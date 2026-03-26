import type { BLEND_MODES, CULL_MODES } from './const';
/**
 * This is a WebGL state, and is is passed to {@link GlStateSystem}.
 *
 * Each mesh rendered may require WebGL to be in a different state.
 * For example you may want different blend mode or to enable polygon offsets
 * @category rendering
 * @advanced
 */
export declare class State {
    /**
     * The data is a unique number based on the states settings.
     * This lets us quickly compare states with a single number rather than looking
     * at all the individual settings.
     */
    data: number;
    /** @internal */
    _blendModeId: number;
    private _blendMode;
    private _polygonOffset;
    constructor();
    /**
     * Activates blending of the computed fragment color values.
     * @default true
     */
    get blend(): boolean;
    set blend(value: boolean);
    /**
     * Activates adding an offset to depth values of polygon's fragments
     * @default false
     */
    get offsets(): boolean;
    set offsets(value: boolean);
    /** The culling settings for this state none - No culling back - Back face culling front - Front face culling */
    set cullMode(value: CULL_MODES);
    get cullMode(): CULL_MODES;
    /**
     * Activates culling of polygons.
     * @default false
     */
    get culling(): boolean;
    set culling(value: boolean);
    /**
     * Activates depth comparisons and updates to the depth buffer.
     * @default false
     */
    get depthTest(): boolean;
    set depthTest(value: boolean);
    /**
     * Enables or disables writing to the depth buffer.
     * @default true
     */
    get depthMask(): boolean;
    set depthMask(value: boolean);
    /**
     * Specifies whether or not front or back-facing polygons can be culled.
     * @default false
     */
    get clockwiseFrontFace(): boolean;
    set clockwiseFrontFace(value: boolean);
    /**
     * The blend mode to be applied when this state is set. Apply a value of `normal` to reset the blend mode.
     * Setting this mode to anything other than NO_BLEND will automatically switch blending on.
     * @default 'normal'
     */
    get blendMode(): BLEND_MODES;
    set blendMode(value: BLEND_MODES);
    /**
     * The polygon offset. Setting this property to anything other than 0 will automatically enable polygon offset fill.
     * @default 0
     */
    get polygonOffset(): number;
    set polygonOffset(value: number);
    toString(): string;
    /**
     * A quickly getting an instance of a State that is configured for 2d rendering.
     * @returns a new State with values set for 2d rendering
     */
    static for2d(): State;
    static default2d: State;
}
