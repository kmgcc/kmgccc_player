/**
 * Copies from one ArrayBuffer to another.
 * Uses Float64Array (8-byte), Float32Array (4-byte), or Uint8Array depending on alignment.
 * @param sourceBuffer - the array buffer to copy from
 * @param destinationBuffer - the array buffer to copy to
 * @param sourceOffset - the byte offset to start copying from (default 0)
 * @param byteLength - the number of bytes to copy (default: min of source available and destination size)
 * @category rendering
 * @advanced
 */
export declare function fastCopy(sourceBuffer: ArrayBuffer | ArrayBufferLike, destinationBuffer: ArrayBuffer | ArrayBufferLike, sourceOffset?: number, byteLength?: number): void;
