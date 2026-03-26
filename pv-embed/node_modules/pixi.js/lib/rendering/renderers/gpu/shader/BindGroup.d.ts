import type { BindResource } from './BindResource';
/**
 * A bind group is a collection of resources that are bound together for use by a shader.
 * They are essentially a wrapper for the WebGPU BindGroup class. But with the added bonus
 * that WebGL can also work with them.
 * @see https://gpuweb.github.io/gpuweb/#dictdef-gpubindgroupdescriptor
 * @example
 * // Create a bind group with a single texture and sampler
 * const bindGroup = new BindGroup({
 *    uTexture: texture.source,
 *    uTexture: texture.style,
 * });
 *
 * Bind groups resources must implement the {@link BindResource} interface.
 * The following resources are supported:
 * - {@link TextureSource}
 * - {@link TextureStyle}
 * - {@link Buffer}
 * - {@link BufferResource}
 * - {@link UniformGroup}
 *
 * The keys in the bind group must correspond to the names of the resources in the GPU program.
 *
 * This bind group class will also watch for changes in its resources ensuring that the changes
 * are reflected in the WebGPU BindGroup.
 * @category rendering
 * @advanced
 */
export declare class BindGroup {
    /** The resources that are bound together for use by a shader. */
    resources: Record<string, BindResource>;
    /**
     * a key used internally to match it up to a WebGPU Bindgroup
     * @internal
     */
    _key: string;
    private _dirty;
    /**
     * Create a new instance eof the Bind Group.
     * @param resources - The resources that are bound together for use by a shader.
     */
    constructor(resources?: Record<string, BindResource>);
    /**
     * Updates the key if its flagged as dirty. This is used internally to
     * match this bind group to a WebGPU BindGroup.
     * @internal
     */
    _updateKey(): void;
    /**
     * Set a resource at a given index. this function will
     * ensure that listeners will be removed from the current resource
     * and added to the new resource.
     * @param resource - The resource to set.
     * @param index - The index to set the resource at.
     */
    setResource(resource: BindResource, index: number): void;
    /**
     * Returns the resource at the current specified index.
     * @param index - The index of the resource to get.
     * @returns - The resource at the specified index.
     */
    getResource(index: number): BindResource;
    /**
     * Used internally to 'touch' each resource, to ensure that the GC
     * knows that all resources in this bind group are still being used.
     * @param now - The current time in milliseconds.
     * @param tick - The current tick.
     * @internal
     */
    _touch(now: number, tick: number): void;
    /** Destroys this bind group and removes all listeners. */
    destroy(): void;
    protected onResourceChange(resource: BindResource): void;
}
