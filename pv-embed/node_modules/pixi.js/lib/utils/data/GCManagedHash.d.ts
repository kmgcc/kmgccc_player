import { type GCable, type GCData } from '../../rendering/renderers/shared/GCSystem';
import { type Renderer } from '../../rendering/renderers/types';
import type EventEmitter from 'eventemitter3';
/**
 * Options for the {@link GCManagedHash}.
 * @internal
 */
export interface GCManagedHashOptions<T extends GCable & {
    uid: number;
} & Pick<EventEmitter, 'once' | 'off'>> {
    renderer: Renderer;
    type: GCData['type'];
    onUnload?: (item: T, ...args: any[]) => void;
    priority?: number;
    name: string;
}
/**
 * A hash for managing renderable and resource resources with GC integration.
 * @internal
 */
export declare class GCManagedHash<T extends GCable & {
    uid: number;
} & Pick<EventEmitter, 'once' | 'off'>> {
    items: Record<number, T>;
    private _renderer;
    private _onUnload?;
    readonly name: string;
    constructor(options: GCManagedHashOptions<T>);
    /**
     * Add an item to the hash. No-op if already added.
     * @param item
     * @returns true if the item was added, false if it was already in the hash
     */
    add(item: T): boolean;
    remove(item: T, ...args: unknown[]): void;
    removeAll(...args: unknown[]): void;
    destroy(...args: unknown[]): void;
}
