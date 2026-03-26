import EventEmitter from 'eventemitter3';
import type { BindResource } from '../../gpu/shader/BindResource';
import type { COMPARE_FUNCTION, SCALE_MODE, WRAP_MODE } from './const';
/**
 * The options for the texture style.
 * @category rendering
 * @advanced
 */
export interface TextureStyleOptions extends Partial<TextureStyle> {
    /** setting this will set wrapModeU,wrapModeV and wrapModeW all at once! */
    addressMode?: WRAP_MODE;
    /** specifies the {{GPUAddressMode|address modes}} for the texture width, height, and depth coordinates, respectively. */
    addressModeU?: WRAP_MODE;
    /** specifies the {{GPUAddressMode|address modes}} for the texture width, height, and depth coordinates, respectively. */
    addressModeV?: WRAP_MODE;
    /** Specifies the {{GPUAddressMode|address modes}} for the texture width, height, and depth coordinates, respectively. */
    addressModeW?: WRAP_MODE;
    /** setting this will set magFilter,minFilter and mipmapFilter all at once!  */
    scaleMode?: SCALE_MODE;
    /** specifies the sampling behavior when the sample footprint is smaller than or equal to one texel. */
    magFilter?: SCALE_MODE;
    /** specifies the sampling behavior when the sample footprint is larger than one texel. */
    minFilter?: SCALE_MODE;
    /** specifies behavior for sampling between mipmap levels. */
    mipmapFilter?: SCALE_MODE;
    /** specifies the minimum and maximum levels of detail, respectively, used internally when sampling a texture. */
    lodMinClamp?: number;
    /** Specifies the minimum and maximum levels of detail, respectively, used internally when sampling a texture. */
    lodMaxClamp?: number;
    /**
     * When provided the sampler will be a comparison sampler with the specified
     * {@link COMPARE_FUNCTION}.
     * Note: Comparison samplers may use filtering, but the sampling results will be
     * implementation-dependent and may differ from the normal filtering rules.
     */
    compare?: COMPARE_FUNCTION;
    /**
     * Specifies the maximum anisotropy value clamp used by the sampler.
     * Note: Most implementations support {@link TextureStyle#maxAnisotropy} values in range
     * between 1 and 16, inclusive. The used value of {@link TextureStyle#maxAnisotropy} will
     * be clamped to the maximum value that the platform supports.
     *
     * setting this to anything higher than 1 will set scale modes to 'linear'
     */
    maxAnisotropy?: number;
}
/**
 * A texture style describes how a texture should be sampled by a shader.
 * @category rendering
 * @advanced
 */
export declare class TextureStyle extends EventEmitter<{
    change: TextureStyle;
    destroy: TextureStyle;
}> implements BindResource {
    /** @internal */
    _resourceType: string;
    /** @internal */
    _touched: number;
    private _sharedResourceId;
    /** default options for the style */
    static readonly defaultOptions: TextureStyleOptions;
    /** */
    addressModeU?: WRAP_MODE;
    /** */
    addressModeV?: WRAP_MODE;
    /** Specifies the {{GPUAddressMode|address modes}} for the texture width, height, and depth coordinates, respectively. */
    addressModeW?: WRAP_MODE;
    /** Specifies the sampling behavior when the sample footprint is smaller than or equal to one texel. */
    magFilter?: SCALE_MODE;
    /** Specifies the sampling behavior when the sample footprint is larger than one texel. */
    minFilter?: SCALE_MODE;
    /** Specifies behavior for sampling between mipmap levels. */
    mipmapFilter?: SCALE_MODE;
    /** */
    lodMinClamp?: number;
    /** Specifies the minimum and maximum levels of detail, respectively, used internally when sampling a texture. */
    lodMaxClamp?: number;
    /**
     * When provided the sampler will be a comparison sampler with the specified
     * {@link COMPARE_FUNCTION}.
     * Note: Comparison samplers may use filtering, but the sampling results will be
     * implementation-dependent and may differ from the normal filtering rules.
     */
    compare?: COMPARE_FUNCTION;
    /**
     * Specifies the maximum anisotropy value clamp used by the sampler.
     * Note: Most implementations support {@link TextureStyle#maxAnisotropy} values in range
     * between 1 and 16, inclusive. The used value of {@link TextureStyle#maxAnisotropy} will
     * be clamped to the maximum value that the platform supports.
     * @internal
     */
    _maxAnisotropy?: number;
    /**
     * Has the style been destroyed?
     * @readonly
     */
    destroyed: boolean;
    /**
     * @param options - options for the style
     */
    constructor(options?: TextureStyleOptions);
    set addressMode(value: WRAP_MODE);
    /** setting this will set wrapModeU,wrapModeV and wrapModeW all at once! */
    get addressMode(): WRAP_MODE;
    set wrapMode(value: WRAP_MODE);
    get wrapMode(): WRAP_MODE;
    set scaleMode(value: SCALE_MODE);
    /** setting this will set magFilter,minFilter and mipmapFilter all at once!  */
    get scaleMode(): SCALE_MODE;
    /** Specifies the maximum anisotropy value clamp used by the sampler. */
    set maxAnisotropy(value: number);
    get maxAnisotropy(): number;
    get _resourceId(): number;
    update(): void;
    private _generateResourceId;
    /** Destroys the style */
    destroy(): void;
}
