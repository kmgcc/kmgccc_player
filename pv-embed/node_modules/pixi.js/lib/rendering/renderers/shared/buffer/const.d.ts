/**
 * Buffer usage flags. they can be combined using the bitwise OR operator
 * eg : BufferUsage.VERTEX | BufferUsage.INDEX
 * @category rendering
 * @advanced
 */
export declare enum BufferUsage {
    /**
     * The buffer can be mapped for reading. (Example: calling mapAsync() with GPUMapMode.READ)
     * May only be combined with COPY_DST.
     */
    MAP_READ = 1,
    /**
     * The buffer can be mapped for writing. (Example: calling mapAsync() with GPUMapMode.WRITE)
     * May only be combined with COPY_SRC.
     */
    MAP_WRITE = 2,
    /**
     * The buffer can be used as the source of a copy operation.
     * (Examples: as the source argument of a copyBufferToBuffer() or copyBufferToTexture() call.)
     */
    COPY_SRC = 4,
    /**
     * The buffer can be used as the destination of a copy or write operation.
     * (Examples: as the destination argument of a copyBufferToBuffer() or
     * copyTextureToBuffer() call, or as the target of a writeBuffer() call.)
     */
    COPY_DST = 8,
    /** The buffer can be used as an index buffer. (Example: passed to setIndexBuffer().) */
    INDEX = 16,
    /** The buffer can be used as a vertex buffer. (Example: passed to setVertexBuffer().) */
    VERTEX = 32,
    /**
     * The buffer can be used as a uniform buffer.
     * (Example: as a bind group entry for a GPUBufferBindingLayout with a buffer.type of "uniform".)
     */
    UNIFORM = 64,
    /**
     * The buffer can be used as a storage buffer.
     * (Example: as a bind group entry for a GPUBufferBindingLayout with a buffer.type of "storage" or "read-only-storage".)
     */
    STORAGE = 128,
    /**
     * The buffer can be used as to store indirect command arguments.
     * (Examples: as the indirectBuffer argument of a drawIndirect() or dispatchWorkgroupsIndirect() call.)
     */
    INDIRECT = 256,
    /**
     * The buffer can be used to capture query results.
     * (Example: as the destination argument of a resolveQuerySet() call.)
     */
    QUERY_RESOLVE = 512,
    /** the buffer will not be updated frequently */
    STATIC = 1024
}
