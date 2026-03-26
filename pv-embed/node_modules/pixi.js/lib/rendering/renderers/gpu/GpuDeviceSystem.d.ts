import { ExtensionType } from '../../../extensions/Extensions';
import type { System } from '../shared/system/System';
import type { GpuPowerPreference } from '../types';
import type { WebGPURenderer } from './WebGPURenderer';
/**
 * The GPU object.
 * Contains the GPU adapter and device.
 * @category rendering
 * @advanced
 */
export interface GPU {
    /** The GPU adapter */
    adapter: GPUAdapter;
    /** The GPU device */
    device: GPUDevice;
}
/**
 * Options for the WebGPU context.
 * @property {GpuPowerPreference} [powerPreference=default] - An optional hint indicating what configuration of GPU
 * is suitable for the WebGPU context, can be `'high-performance'` or `'low-power'`.
 * Setting to `'high-performance'` will prioritize rendering performance over power consumption,
 * while setting to `'low-power'` will prioritize power saving over rendering performance.
 * @property {boolean} [forceFallbackAdapter=false] - Force the use of the fallback adapter
 * @category rendering
 * @advanced
 */
export interface GpuContextOptions {
    /**
     * An optional hint indicating what configuration of GPU is suitable for the WebGPU context,
     * can be `'high-performance'` or `'low-power'`.
     * Setting to `'high-performance'` will prioritize rendering performance over power consumption,
     * while setting to `'low-power'` will prioritize power saving over rendering performance.
     * @default undefined
     */
    powerPreference?: GpuPowerPreference;
    /**
     * Force the use of the fallback adapter
     * @default false
     */
    forceFallbackAdapter: boolean;
    /** Using shared device and adaptor from other engine */
    gpu?: GPU;
}
/**
 * System plugin to the renderer to manage the context.
 * @class
 * @category rendering
 * @advanced
 */
export declare class GpuDeviceSystem implements System<GpuContextOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "device";
    };
    /** The default options for the GpuDeviceSystem. */
    static defaultOptions: GpuContextOptions;
    /** The GPU device */
    gpu: GPU;
    private _renderer;
    private _initPromise;
    /**
     * @param {WebGPURenderer} renderer - The renderer this System works for.
     */
    constructor(renderer: WebGPURenderer);
    init(options: GpuContextOptions): Promise<void>;
    /**
     * Handle the context change event
     * @param gpu
     */
    protected contextChange(gpu: GPU): void;
    /**
     * Helper class to create a WebGL Context
     * @param {object} options - An options object that gets passed in to the canvas element containing the
     *    context attributes
     * @see https://developer.mozilla.org/en/docs/Web/API/HTMLCanvasElement/getContext
     * @returns {WebGLRenderingContext} the WebGL context
     */
    private _createDeviceAndAdaptor;
    destroy(): void;
}
