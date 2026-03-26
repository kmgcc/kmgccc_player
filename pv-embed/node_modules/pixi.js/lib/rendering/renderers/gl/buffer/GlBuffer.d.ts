import { type GPUData } from '../../../../scene/view/ViewContainer';
import type { BUFFER_TYPE } from './const';
/** @internal */
export declare class GlBuffer implements GPUData {
    buffer: WebGLBuffer;
    updateID: number;
    byteLength: number;
    type: number;
    _lastBindBaseLocation: number;
    _lastBindCallId: number;
    constructor(buffer: WebGLBuffer, type: BUFFER_TYPE);
    destroy(): void;
}
