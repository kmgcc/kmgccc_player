import { Buffer } from '../../buffer/Buffer';
import type { TypedArray } from '../../buffer/Buffer';
/**
 * Converts something into a buffer. If it is already a buffer it will pass it through
 * if it is a number array it will convert it to a float32 array before being passed into a buffer
 * the buffer will be created with the correct usage flags for geometry attributes
 * @param buffer - number array
 * @param index - is this an index buffer?
 * @returns a buffer
 * @category rendering
 * @internal
 */
export declare function ensureIsBuffer(buffer: Buffer | TypedArray | number[], index: boolean): Buffer;
