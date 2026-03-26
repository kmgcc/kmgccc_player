import { Bounds } from '../../container/bounds/Bounds';
import { ViewContainer, type ViewContainerOptions } from '../../view/ViewContainer';
import { type ParticleBuffer } from './ParticleBuffer';
import '../init';
import type { Instruction } from '../../../rendering/renderers/shared/instructions/Instruction';
import type { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import type { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import type { ContainerChild } from '../../container/Container';
import type { DestroyOptions } from '../../container/destroyTypes';
import type { IParticle } from './Particle';
import type { ParticleRendererProperty } from './particleData';
/**
 * Represents the properties of a particle that can be dynamically updated each frame.
 * These properties control which aspects of particles are recalculated during rendering.
 * Setting a property to true enables per-frame updates, while false only updates when manually triggered.
 * @example
 * ```ts
 * // Create a particle container with dynamic position and rotation
 * const container = new ParticleContainer({
 *     dynamicProperties: {
 *         position: true,  // Update positions each frame
 *         rotation: true,  // Update rotations each frame
 *         vertex: false,   // Static vertices
 *         uvs: false,     // Static texture coordinates
 *         color: false     // Static colors
 *     }
 * });
 *
 * // Create a fully dynamic particle container
 * const dynamicContainer = new ParticleContainer({
 *     dynamicProperties: {
 *         vertex: true,    // Dynamic mesh deformation
 *         position: true,  // Dynamic movement
 *         rotation: true,  // Dynamic spinning
 *         uvs: true,      // Dynamic texture animation
 *         color: true     // Dynamic coloring
 *     }
 * });
 * ```
 * @see {@link ParticleContainer} For the main particle container class
 * @see {@link ParticleContainerOptions} For all container configuration options
 * @category scene
 * @standard
 */
export interface ParticleProperties {
    /**
     * When true, vertex positions are updated each frame.
     * Useful for mesh deformation effects.
     * @default false
     */
    vertex?: boolean;
    /**
     * When true, particle positions are updated each frame.
     * Essential for moving particles.
     * @default true
     */
    position?: boolean;
    /**
     * When true, rotation values are updated each frame.
     * Needed for spinning particles.
     * @default false
     */
    rotation?: boolean;
    /**
     * When true, texture coordinates are updated each frame.
     * Required for texture animation.
     * @default false
     */
    uvs?: boolean;
    /**
     * When true, color values are updated each frame.
     * Enables color transitions and alpha changes.
     * @default false
     */
    color?: boolean;
}
/**
 * Options for configuring a ParticleContainer. Controls how particles are rendered, updated, and managed.
 * @example
 * ```ts
 * // Create a basic particle container
 * const container = new ParticleContainer({
 *     texture: Texture.from('particle.png'),
 *     particles: [
 *         new Particle(texture),
 *         new Particle(texture)
 *     ],
 *     dynamicProperties: {
 *         position: true,  // Update positions each frame
 *         rotation: true   // Update rotations each frame
 *     }
 * });
 * ```
 * @see {@link ParticleContainer} For the main particle container class
 * @see {@link ParticleProperties} For dynamic property configuration
 * @template T The type of particles in the container. Must implement {@link IParticle}. * @category scene
 * @standard
 * @noInheritDoc
 */
export interface ParticleContainerOptions<T extends IParticle = IParticle> extends PixiMixins.ParticleContainerOptions, Omit<ViewContainerOptions, 'children'> {
    /**
     * Specifies which particle properties should update each frame.
     * Set properties to true for per-frame updates, false for static values.
     * @default { position: true, rotation: false, vertex: false, uvs: false, color: false }
     */
    dynamicProperties?: ParticleProperties & Record<string, boolean>;
    /**
     * Custom shader for rendering particles. Allows for custom visual effects.
     * @advanced
     */
    shader?: Shader;
    /**
     * When true, particle positions are rounded to the nearest pixel.
     * Helps achieve crisp rendering at the cost of smooth motion.
     * @default false
     */
    roundPixels?: boolean;
    /**
     * The texture used for all particles in this container.
     * If not provided, uses the texture of the first particle added.
     */
    texture?: Texture;
    /** Initial array of particles to add to the container. All particles must share the same base texture. */
    particles?: T[];
}
export interface ParticleContainer extends PixiMixins.ParticleContainer, ViewContainer<ParticleBuffer> {
}
/**
 * The ParticleContainer class is a highly optimized container that can render 1000s or particles at great speed.
 *
 * A ParticleContainer is specialized in that it can only contain and render particles. Particles are
 * lightweight objects that use minimal memory, which helps boost performance.
 *
 * It can render particles EXTREMELY fast!
 *
 * The tradeoff of using a ParticleContainer is that most advanced functionality is unavailable. Particles are simple
 * and cannot have children, filters, masks, etc. They possess only the basic properties: position, scale, rotation,
 * and color.
 *
 * All particles must share the same texture source (using something like a sprite sheet works well here).
 *
 * When creating a ParticleContainer, a developer can specify which of these properties are static and which are dynamic.
 * - Static properties are only updated when you add or remove a child, or when the `update` function is called.
 * - Dynamic properties are updated every frame.
 *
 * It is up to the developer to specify which properties are static and which are dynamic. Generally, the more static
 * properties you have (i.e., those that do not change per frame), the faster the rendering.
 *
 * If the developer modifies the children order or any static properties of the particle, they must call the `update` method.
 *
 * By default, only the `position` property is set to dynamic, which makes rendering very fast!
 *
 * Developers can also provide a custom shader to the particle container, allowing them to render particles in a custom way.
 *
 * To help with performance, the particle containers bounds are not calculated.
 * It's up to the developer to set the boundsArea property.
 *
 * It's extremely easy to use. Below is an example of rendering thousands of sprites at lightning speed.
 *
 * --------- EXPERIMENTAL ---------
 *
 * This is a new API, things may change and it may not work as expected.
 * We want to hear your feedback as we go!
 *
 * --------------------------------
 * @example
 * ```ts
 * import { ParticleContainer, Particle } from 'pixi.js';
 *
 * const container = new ParticleContainer();
 *
 * for (let i = 0; i < 100; ++i)
 * {
 *     let particle = new Particle(texture);
 *     container.addParticle(particle);
 * }
 * ```
 * @template T The type of particles in the container. Must implement {@link IParticle}.
 * @category scene
 * @standard
 */
export declare class ParticleContainer<T extends IParticle = IParticle> extends ViewContainer<ParticleBuffer> implements Instruction {
    /**
     * Defines the default options for creating a ParticleContainer.
     * @example
     * ```ts
     * // Change defaults globally
     * ParticleContainer.defaultOptions = {
     *     dynamicProperties: {
     *         position: true,  // Update positions each frame
     *         rotation: true,  // Update rotations each frame
     *         vertex: false,   // Static vertices
     *         uvs: false,      // Static texture coordinates
     *         color: false     // Static colors
     *     },
     *     roundPixels: true // Enable pixel rounding for crisp rendering
     * };
     * ```
     * @property {Record<string, boolean>} dynamicProperties - Specifies which properties are dynamic.
     * @property {boolean} roundPixels - Indicates if pixels should be rounded.
     */
    static defaultOptions: Pick<ParticleContainerOptions, 'dynamicProperties' | 'roundPixels'>;
    /**
     * The unique identifier for the render pipe of this ParticleContainer.
     * @internal
     */
    readonly renderPipeId: string;
    /** @internal */
    batched: boolean;
    /**
     * A record of properties and their corresponding ParticleRendererProperty.
     * @internal
     */
    _properties: Record<string, ParticleRendererProperty>;
    /**
     * Indicates if the children of this ParticleContainer have changed and need to be updated.
     * @internal
     */
    _childrenDirty: boolean;
    /**
     * An array of particles that are children of this ParticleContainer.
     * This array can be modified directly for performance, but the 'update' method
     * must be called afterwards to ensure the container is rendered correctly.
     * @example
     * ```ts
     * const container = new ParticleContainer();
     *
     * // Add particles directly to the array
     * container.particleChildren.push(
     *     new Particle(texture),
     *     new Particle(texture)
     * );
     * container.update(); // Required after direct modification
     *
     * // Modify existing particles
     * container.particleChildren.forEach(particle => {
     *     particle.position.x += 10;
     * });
     *
     * // Remove particles
     * container.particleChildren.length = 0; // Clear all
     * container.update();
     * ```
     * @see {@link ParticleContainer#update} For updating after modifications
     * @see {@link ParticleContainer#addParticle} For a safer way to add particles
     * @see {@link ParticleContainer#removeParticle} For a safer way to remove particles
     */
    particleChildren: T[];
    /**
     * The shader used for rendering particles in this ParticleContainer.
     * @advanced
     */
    shader: Shader;
    /**
     * The texture used for rendering particles in this ParticleContainer. All particles
     * must share the same base texture for optimal performance.
     *
     * > [!NOTE]
     * > If not set, the texture of the first particle added to this container will be used.
     * @example
     * ```ts
     * const container = new ParticleContainer();
     * // Set texture for all particles
     * container.texture = Texture.from('particle.png');
     *
     * // Create particles using container's texture
     * for (let i = 0; i < 100; i++) {
     *     const particle = new Particle(container.texture);
     *     container.addParticle(particle); // Will use the particles texture if not set
     * }
     * ```
     * @default null
     * @see {@link ParticleContainerOptions#texture} For setting texture via constructor
     * @see {@link Particle} For creating particles with textures
     */
    texture: Texture;
    /**
     * @param options - The options for creating the sprite.
     */
    constructor(options?: ParticleContainerOptions<T>);
    /**
     * Adds one or more particles to the container. The particles will be rendered using the container's shared texture
     * and properties. When adding multiple particles, they must all share the same base texture.
     * @example
     * ```ts
     * const container = new ParticleContainer();
     *
     * // Add a single particle
     * const particle = new Particle(Assets.get('particleTexture'));
     * container.addParticle(particle);
     *
     * // Add multiple particles at once
     * const particles = [
     *     new Particle(Assets.get('particleTexture')),
     *     new Particle(Assets.get('particleTexture')),
     *     new Particle(Assets.get('particleTexture'))
     * ];
     *
     * container.addParticle(...particles);
     * ```
     * @param children - The Particle(s) to add to the container
     * @returns The first particle that was added, for method chaining
     * @see {@link ParticleContainer#texture} For setting the shared texture
     * @see {@link ParticleContainer#update} For updating after modifications
     */
    addParticle(...children: T[]): T;
    /**
     * Removes one or more particles from the container. The particles must already be children
     * of this container to be removed.
     * @example
     * ```ts
     * // Remove a single particle
     * container.removeParticle(particle1);
     *
     * // Remove multiple particles at once
     * container.removeParticle(particle2, particle3);
     * ```
     * @param children - The Particle(s) to remove from the container
     * @returns The first particle that was removed, for method chaining
     * @see {@link ParticleContainer#particleChildren} For accessing all particles
     * @see {@link ParticleContainer#removeParticles} For removing particles by index
     * @see {@link ParticleContainer#removeParticleAt} For removing a particle at a specific index
     */
    removeParticle(...children: T[]): T;
    /**
     * Updates the particle container's internal state. Call this method after manually modifying
     * the particleChildren array or when changing static properties of particles.
     * @example
     * ```ts
     * // Batch modify particles
     * container.particleChildren.push(...particles);
     * container.update(); // Required after direct array modification
     *
     * // Update static properties
     * container.particleChildren.forEach(particle => {
     *     particle.position.set(
     *         Math.random() * 800,
     *         Math.random() * 600
     *     );
     * });
     * container.update(); // Required after changing static positions
     * ```
     * @see {@link ParticleProperties} For configuring dynamic vs static properties
     * @see {@link ParticleContainer#particleChildren} For direct array access
     */
    update(): void;
    protected onViewUpdate(): void;
    /**
     * Returns a static empty bounds object since ParticleContainer does not calculate bounds automatically
     * for performance reasons. Use the `boundsArea` property to manually set container bounds.
     * @example
     * ```ts
     * const container = new ParticleContainer({
     *     texture: Texture.from('particle.png')
     * });
     *
     * // Default bounds are empty
     * console.log(container.bounds); // Bounds(0, 0, 0, 0)
     *
     * // Set manual bounds for the particle area
     * container.boundsArea = {
     *     minX: 0,
     *     minY: 0,
     *     maxX: 800,
     *     maxY: 600
     * };
     * ```
     * @readonly
     * @returns {Bounds} An empty bounds object (0,0,0,0)
     * @see {@link Container#boundsArea} For manually setting container bounds
     * @see {@link Bounds} For bounds object structure
     */
    get bounds(): Bounds;
    /** @private */
    protected updateBounds(): void;
    /**
     * Destroys this sprite renderable and optionally its texture.
     * @param options - Options parameter. A boolean will act as if all options
     *  have been set to that value
     * @example
     * particleContainer.destroy();
     * particleContainer.destroy(true);
     * particleContainer.destroy({ texture: true, textureSource: true, children: true });
     */
    destroy(options?: DestroyOptions): void;
    /**
     * Removes all particles from this container that are within the begin and end indexes.
     * @param beginIndex - The beginning position.
     * @param endIndex - The ending position. Default value is size of the container.
     * @returns - List of removed particles
     */
    removeParticles(beginIndex?: number, endIndex?: number): T[];
    /**
     * Removes a particle from the specified index position.
     * @param index - The index to get the particle from
     * @returns The particle that was removed.
     */
    removeParticleAt<U extends T = T>(index: number): U;
    /**
     * Adds a particle to the container at a specified index. If the index is out of bounds an error will be thrown.
     * If the particle is already in this container, it will be moved to the specified index.
     * @param {Container} child - The particle to add.
     * @param {number} index - The absolute index where the particle will be positioned at the end of the operation.
     * @returns {Container} The particle that was added.
     */
    addParticleAt<U extends T = T>(child: U, index: number): U;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.addParticle()` instead.
     * @param {...any} _children
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    addChild<U extends ContainerChild[]>(..._children: U): U[0];
    /**
     * This method is not available in ParticleContainer.
     * Calling this method will throw an error. Please use `ParticleContainer.removeParticle()` instead.
     * @param {...any} _children
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    removeChild<U extends ContainerChild[]>(..._children: U): U[0];
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.removeParticles()` instead.
     * @param {number} [_beginIndex]
     * @param {number} [_endIndex]
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    removeChildren(_beginIndex?: number, _endIndex?: number): ContainerChild[];
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.removeParticleAt()` instead.
     * @param {number} _index
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    removeChildAt<U extends ContainerChild>(_index: number): U;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.getParticleAt()` instead.
     * @param {number} _index
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    getChildAt<U extends ContainerChild>(_index: number): U;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.setParticleIndex()` instead.
     * @param {ContainerChild} _child
     * @param {number} _index
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    setChildIndex(_child: ContainerChild, _index: number): void;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.getParticleIndex()` instead.
     * @param {ContainerChild} _child
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    getChildIndex(_child: ContainerChild): number;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.addParticleAt()` instead.
     * @param {ContainerChild} _child
     * @param {number} _index
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    addChildAt<U extends ContainerChild>(_child: U, _index: number): U;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error. Please use `ParticleContainer.swapParticles()` instead.
     * @param {ContainerChild} _child
     * @param {ContainerChild} _child2
     * @ignore
     */
    swapChildren<U extends ContainerChild>(_child: U, _child2: U): void;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error.
     * @param _child - The child to reparent
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    reparentChild(..._child: ContainerChild[]): any;
    /**
     * This method is not available in ParticleContainer.
     *
     * Calling this method will throw an error.
     * @param _child - The child to reparent
     * @param _index - The index to reparent the child to
     * @throws {Error} Always throws an error as this method is not available.
     * @ignore
     */
    reparentChildAt(_child: ContainerChild, _index: number): any;
}
