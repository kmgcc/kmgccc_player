import type { System } from '../system/System';
import type { UboElement, UboLayout, UniformData, UniformsSyncCallback } from './types';
import type { UniformGroup } from './UniformGroup';
/** @internal */
export interface UboAdaptor {
    createUboElements: (uniformData: UniformData[]) => UboLayout;
    generateUboSync: (uboElements: UboElement[]) => UniformsSyncCallback;
}
/**
 * System plugin to the renderer to manage uniform buffers.
 * @category rendering
 * @advanced
 */
export declare class UboSystem implements System {
    /** Cache of uniform buffer layouts and sync functions, so we don't have to re-create them */
    private _syncFunctionHash;
    private readonly _adaptor;
    constructor(adaptor: UboAdaptor);
    /**
     * Overridable function by `pixi.js/unsafe-eval` to silence
     * throwing an error if platform doesn't support unsafe-evals.
     * @private
     */
    private _systemCheck;
    ensureUniformGroup(uniformGroup: UniformGroup): void;
    getUniformGroupData(uniformGroup: UniformGroup): {
        layout: UboLayout;
        syncFunction: (uniforms: Record<string, any>, data: Float32Array, dataInt32: Int32Array, offset: number) => void;
    };
    private _initUniformGroup;
    private _generateUboSync;
    syncUniformGroup(uniformGroup: UniformGroup, data?: Float32Array, offset?: number): boolean;
    updateUniformGroup(uniformGroup: UniformGroup): boolean;
    destroy(): void;
}
