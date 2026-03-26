import { ExtensionType } from '../../../../extensions/Extensions';
import { GCManagedHash } from '../../../../utils/data/GCManagedHash';
import { GlBuffer } from './GlBuffer';
import type { Buffer } from '../../shared/buffer/Buffer';
import type { System } from '../../shared/system/System';
import type { GlRenderingContext } from '../context/GlRenderingContext';
import type { WebGLRenderer } from '../WebGLRenderer';
/**
 * System plugin to the renderer to manage buffers.
 *
 * WebGL uses Buffers as a way to store objects to the GPU.
 * This system makes working with them a lot easier.
 *
 * Buffers are used in three main places in WebGL
 * - geometry information
 * - Uniform information (via uniform buffer objects - a WebGL 2 only feature)
 * - Transform feedback information. (WebGL 2 only feature)
 *
 * This system will handle the binding of buffers to the GPU as well as uploading
 * them. With this system, you never need to work directly with GPU buffers, but instead work with
 * the Buffer class.
 * @class
 * @category rendering
 * @advanced
 */
export declare class GlBufferSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "buffer";
    };
    /** @internal */
    _gl: GlRenderingContext;
    protected _managedBuffers: GCManagedHash<Buffer>;
    /** Cache keeping track of the base bound buffer bases */
    private _boundBufferBases;
    private _renderer;
    private _minBaseLocation;
    private _maxBindings;
    private _nextBindBaseIndex;
    private _bindCallId;
    /**
     * @param {Renderer} renderer - The renderer this System works for.
     */
    constructor(renderer: WebGLRenderer);
    /** @ignore */
    destroy(): void;
    /** Sets up the renderer context and necessary buffers. */
    protected contextChange(): void;
    getGlBuffer(buffer: Buffer): GlBuffer;
    /**
     * This binds specified buffer. On first run, it will create the webGL buffers for the context too
     * @param buffer - the buffer to bind to the renderer
     */
    bind(buffer: Buffer): void;
    /**
     * Binds an uniform buffer to at the given index.
     *
     * A cache is used so a buffer will not be bound again if already bound.
     * @param glBuffer - the buffer to bind
     * @param index - the base index to bind it to.
     */
    bindBufferBase(glBuffer: GlBuffer, index: number): void;
    nextBindBase(hasTransformFeedback: boolean): void;
    freeLocationForBufferBase(glBuffer: GlBuffer): number;
    getLastBindBaseLocation(glBuffer: GlBuffer): number;
    /**
     * Binds a buffer whilst also binding its range.
     * This will make the buffer start from the offset supplied rather than 0 when it is read.
     * @param glBuffer - the buffer to bind
     * @param index - the base index to bind at, defaults to 0
     * @param offset - the offset to bind at (this is blocks of 256). 0 = 0, 1 = 256, 2 = 512 etc
     * @param size - the size to bind at (this is blocks of 256).
     */
    bindBufferRange(glBuffer: GlBuffer, index?: number, offset?: number, size?: number): void;
    /**
     * Will ensure the data in the buffer is uploaded to the GPU.
     * @param {Buffer} buffer - the buffer to update
     */
    updateBuffer(buffer: Buffer): GlBuffer;
    /**
     * dispose all WebGL resources of all managed buffers
     * @param contextLost
     */
    destroyAll(contextLost?: boolean): void;
    protected onBufferUnload(buffer: Buffer, contextLost?: boolean): void;
    /**
     * creates and attaches a GLBuffer object tied to the current context.
     * @param buffer
     * @protected
     */
    protected createGLBuffer(buffer: Buffer): GlBuffer;
    resetState(): void;
}
