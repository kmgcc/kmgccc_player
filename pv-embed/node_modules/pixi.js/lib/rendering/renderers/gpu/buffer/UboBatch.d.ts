/** @internal */
export declare class UboBatch {
    data: Float32Array;
    private readonly _minUniformOffsetAlignment;
    byteIndex: number;
    constructor({ minUniformOffsetAlignment }: {
        minUniformOffsetAlignment: number;
    });
    clear(): void;
    addEmptyGroup(size: number): number;
    addGroup(array: Float32Array): number;
    destroy(): void;
}
