'use strict';

var Bounds = require('../../container/bounds/Bounds.js');
var ViewContainer = require('../../view/ViewContainer.js');
var particleData = require('./particleData.js');
require('../init.js');

"use strict";
const emptyBounds = new Bounds.Bounds(0, 0, 0, 0);
const _ParticleContainer = class _ParticleContainer extends ViewContainer.ViewContainer {
  /**
   * @param options - The options for creating the sprite.
   */
  constructor(options = {}) {
    options = {
      ..._ParticleContainer.defaultOptions,
      ...options,
      dynamicProperties: {
        ..._ParticleContainer.defaultOptions.dynamicProperties,
        ...options?.dynamicProperties
      }
    };
    const { dynamicProperties, shader, roundPixels, texture, particles, ...rest } = options;
    super({
      label: "ParticleContainer",
      ...rest
    });
    /**
     * The unique identifier for the render pipe of this ParticleContainer.
     * @internal
     */
    this.renderPipeId = "particle";
    /** @internal */
    this.batched = false;
    /**
     * Indicates if the children of this ParticleContainer have changed and need to be updated.
     * @internal
     */
    this._childrenDirty = false;
    this.texture = texture || null;
    this.shader = shader;
    this._properties = {};
    for (const key in particleData.particleData) {
      const property = particleData.particleData[key];
      const dynamic = dynamicProperties[key];
      this._properties[key] = {
        ...property,
        dynamic
      };
    }
    this.allowChildren = true;
    this.roundPixels = roundPixels ?? false;
    this.particleChildren = particles ?? [];
  }
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
  addParticle(...children) {
    for (let i = 0; i < children.length; i++) {
      this.particleChildren.push(children[i]);
    }
    this.onViewUpdate();
    return children[0];
  }
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
  removeParticle(...children) {
    let didRemove = false;
    for (let i = 0; i < children.length; i++) {
      const index = this.particleChildren.indexOf(children[i]);
      if (index > -1) {
        this.particleChildren.splice(index, 1);
        didRemove = true;
      }
    }
    if (didRemove) this.onViewUpdate();
    return children[0];
  }
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
  update() {
    this._childrenDirty = true;
  }
  onViewUpdate() {
    this._childrenDirty = true;
    super.onViewUpdate();
  }
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
  get bounds() {
    return emptyBounds;
  }
  /** @private */
  updateBounds() {
  }
  /**
   * Destroys this sprite renderable and optionally its texture.
   * @param options - Options parameter. A boolean will act as if all options
   *  have been set to that value
   * @example
   * particleContainer.destroy();
   * particleContainer.destroy(true);
   * particleContainer.destroy({ texture: true, textureSource: true, children: true });
   */
  destroy(options = false) {
    super.destroy(options);
    const destroyTexture = typeof options === "boolean" ? options : options?.texture;
    if (destroyTexture) {
      const destroyTextureSource = typeof options === "boolean" ? options : options?.textureSource;
      const texture = this.texture ?? this.particleChildren[0]?.texture;
      if (texture) {
        texture.destroy(destroyTextureSource);
      }
    }
    this.texture = null;
    this.shader?.destroy();
  }
  /**
   * Removes all particles from this container that are within the begin and end indexes.
   * @param beginIndex - The beginning position.
   * @param endIndex - The ending position. Default value is size of the container.
   * @returns - List of removed particles
   */
  removeParticles(beginIndex, endIndex) {
    beginIndex ?? (beginIndex = 0);
    endIndex ?? (endIndex = this.particleChildren.length);
    const children = this.particleChildren.splice(
      beginIndex,
      endIndex - beginIndex
    );
    this.onViewUpdate();
    return children;
  }
  /**
   * Removes a particle from the specified index position.
   * @param index - The index to get the particle from
   * @returns The particle that was removed.
   */
  removeParticleAt(index) {
    const child = this.particleChildren.splice(index, 1);
    this.onViewUpdate();
    return child[0];
  }
  /**
   * Adds a particle to the container at a specified index. If the index is out of bounds an error will be thrown.
   * If the particle is already in this container, it will be moved to the specified index.
   * @param {Container} child - The particle to add.
   * @param {number} index - The absolute index where the particle will be positioned at the end of the operation.
   * @returns {Container} The particle that was added.
   */
  addParticleAt(child, index) {
    this.particleChildren.splice(index, 0, child);
    this.onViewUpdate();
    return child;
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.addParticle()` instead.
   * @param {...any} _children
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  addChild(..._children) {
    throw new Error(
      "ParticleContainer.addChild() is not available. Please use ParticleContainer.addParticle()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   * Calling this method will throw an error. Please use `ParticleContainer.removeParticle()` instead.
   * @param {...any} _children
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  removeChild(..._children) {
    throw new Error(
      "ParticleContainer.removeChild() is not available. Please use ParticleContainer.removeParticle()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.removeParticles()` instead.
   * @param {number} [_beginIndex]
   * @param {number} [_endIndex]
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  removeChildren(_beginIndex, _endIndex) {
    throw new Error(
      "ParticleContainer.removeChildren() is not available. Please use ParticleContainer.removeParticles()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.removeParticleAt()` instead.
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  removeChildAt(_index) {
    throw new Error(
      "ParticleContainer.removeChildAt() is not available. Please use ParticleContainer.removeParticleAt()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.getParticleAt()` instead.
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  getChildAt(_index) {
    throw new Error(
      "ParticleContainer.getChildAt() is not available. Please use ParticleContainer.getParticleAt()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.setParticleIndex()` instead.
   * @param {ContainerChild} _child
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  setChildIndex(_child, _index) {
    throw new Error(
      "ParticleContainer.setChildIndex() is not available. Please use ParticleContainer.setParticleIndex()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.getParticleIndex()` instead.
   * @param {ContainerChild} _child
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  getChildIndex(_child) {
    throw new Error(
      "ParticleContainer.getChildIndex() is not available. Please use ParticleContainer.getParticleIndex()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.addParticleAt()` instead.
   * @param {ContainerChild} _child
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  addChildAt(_child, _index) {
    throw new Error(
      "ParticleContainer.addChildAt() is not available. Please use ParticleContainer.addParticleAt()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error. Please use `ParticleContainer.swapParticles()` instead.
   * @param {ContainerChild} _child
   * @param {ContainerChild} _child2
   * @ignore
   */
  swapChildren(_child, _child2) {
    throw new Error(
      "ParticleContainer.swapChildren() is not available. Please use ParticleContainer.swapParticles()"
    );
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error.
   * @param _child - The child to reparent
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  reparentChild(..._child) {
    throw new Error("ParticleContainer.reparentChild() is not available with the particle container");
  }
  /**
   * This method is not available in ParticleContainer.
   *
   * Calling this method will throw an error.
   * @param _child - The child to reparent
   * @param _index - The index to reparent the child to
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  reparentChildAt(_child, _index) {
    throw new Error("ParticleContainer.reparentChildAt() is not available with the particle container");
  }
};
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
_ParticleContainer.defaultOptions = {
  /** Specifies which properties are dynamic. */
  dynamicProperties: {
    /** Indicates if vertex positions are dynamic. */
    vertex: false,
    /** Indicates if particle positions are dynamic. */
    position: true,
    /** Indicates if particle rotations are dynamic. */
    rotation: false,
    /** Indicates if UV coordinates are dynamic. */
    uvs: false,
    /** Indicates if particle colors are dynamic. */
    color: false
  },
  /** Indicates if pixels should be rounded for rendering. */
  roundPixels: false
};
let ParticleContainer = _ParticleContainer;

exports.ParticleContainer = ParticleContainer;
//# sourceMappingURL=ParticleContainer.js.map
