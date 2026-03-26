import { warn } from '../../utils/logging/warn.mjs';
import { Container } from '../container/Container.mjs';

"use strict";
const _RenderLayer = class _RenderLayer extends Container {
  /**
   * Creates a new RenderLayer instance
   * @param options - Configuration options for the RenderLayer
   * @param {boolean} [options.sortableChildren=false] - If true, layer children will be automatically sorted each render
   * @param {Function} [options.sortFunction] - Custom function to sort layer children. Default sorts by zIndex
   */
  constructor(options = {}) {
    options = { ..._RenderLayer.defaultOptions, ...options };
    super();
    /**
     * The list of objects that this layer is responsible for rendering. Objects in this list maintain
     * their original parent in the scene graph but are rendered as part of this layer.
     * @example
     * ```ts
     * const layer = new RenderLayer();
     * const sprite = new Sprite(texture);
     *
     * // Add sprite to scene graph for transforms
     * container.addChild(sprite);
     *
     * // Add to layer for render order control
     * layer.attach(sprite);
     * console.log(layer.renderLayerChildren.length); // 1
     *
     * // Access objects in the layer
     * layer.renderLayerChildren.forEach(child => {
     *     console.log('Layer child:', child);
     * });
     *
     * // Check if object is in layer
     * const isInLayer = layer.renderLayerChildren.includes(sprite);
     *
     * // Clear all objects from layer
     * layer.detachAll();
     * console.log(layer.renderLayerChildren.length); // 0
     * ```
     * @readonly
     * @see {@link RenderLayer#attach} For adding objects to the layer
     * @see {@link RenderLayer#detach} For removing objects from the layer
     * @see {@link RenderLayer#detachAll} For removing all objects from the layer
     */
    this.renderLayerChildren = [];
    this.sortableChildren = options.sortableChildren;
    this.sortFunction = options.sortFunction;
  }
  /**
   * Adds one or more Containers to this render layer. The Containers will be rendered as part of this layer
   * while maintaining their original parent in the scene graph.
   *
   * If the Container already belongs to a layer, it will be removed from the old layer before being added to this one.
   * @example
   * ```ts
   * const layer = new RenderLayer();
   * const container = new Container();
   * const sprite1 = new Sprite(texture1);
   * const sprite2 = new Sprite(texture2);
   *
   * // Add sprites to scene graph for transforms
   * container.addChild(sprite1, sprite2);
   *
   * // Add sprites to layer for render order control
   * layer.attach(sprite1, sprite2);
   *
   * // Add single sprite with type checking
   * const typedSprite = layer.attach<Sprite>(new Sprite(texture3));
   * typedSprite.tint = 'red';
   *
   * // Automatically removes from previous layer if needed
   * const otherLayer = new RenderLayer();
   * otherLayer.attach(sprite1); // Removes from previous layer
   * ```
   * @param children - The Container(s) to add to this layer. Can be any Container or array of Containers.
   * @returns The first child that was added, for method chaining
   * @see {@link RenderLayer#detach} For removing objects from the layer
   * @see {@link RenderLayer#detachAll} For removing all objects from the layer
   * @see {@link Container#addChild} For adding to scene graph hierarchy
   */
  attach(...children) {
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      if (child.parentRenderLayer) {
        if (child.parentRenderLayer === this) continue;
        child.parentRenderLayer.detach(child);
      }
      this.renderLayerChildren.push(child);
      child.parentRenderLayer = this;
      const renderGroup = this.renderGroup || this.parentRenderGroup;
      if (renderGroup) {
        renderGroup.structureDidChange = true;
      }
    }
    return children[0];
  }
  /**
   * Removes one or more Containers from this render layer. The Containers will maintain their
   * original parent in the scene graph but will no longer be rendered as part of this layer.
   * @example
   * ```ts
   * const layer = new RenderLayer();
   * const container = new Container();
   * const sprite1 = new Sprite(texture1);
   * const sprite2 = new Sprite(texture2);
   *
   * // Add sprites to scene graph and layer
   * container.addChild(sprite1, sprite2);
   * layer.attach(sprite1, sprite2);
   *
   * // Remove single sprite from layer
   * layer.detach(sprite1);
   * // sprite1 is still child of container but not rendered in layer
   *
   * // Remove multiple sprites at once
   * const otherLayer = new RenderLayer();
   * otherLayer.attach(sprite3, sprite4);
   * otherLayer.detach(sprite3, sprite4);
   *
   * // Type-safe detachment
   * const typedSprite = layer.detach<Sprite>(spriteInLayer);
   * typedSprite.texture = newTexture; // TypeScript knows this is a Sprite
   * ```
   * @param children - The Container(s) to remove from this layer
   * @returns The first child that was removed, for method chaining
   * @see {@link RenderLayer#attach} For adding objects to the layer
   * @see {@link RenderLayer#detachAll} For removing all objects from the layer
   * @see {@link Container#removeChild} For removing from scene graph hierarchy
   */
  detach(...children) {
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      const index = this.renderLayerChildren.indexOf(child);
      if (index !== -1) {
        this.renderLayerChildren.splice(index, 1);
      }
      child.parentRenderLayer = null;
      const renderGroup = this.renderGroup || this.parentRenderGroup;
      if (renderGroup) {
        renderGroup.structureDidChange = true;
      }
    }
    return children[0];
  }
  /**
   * Removes all objects from this render layer. Objects will maintain their
   * original parent in the scene graph but will no longer be rendered as part of this layer.
   * @example
   * ```ts
   * const layer = new RenderLayer();
   * const container = new Container();
   *
   * // Add multiple sprites to scene graph and layer
   * const sprites = [
   *     new Sprite(texture1),
   *     new Sprite(texture2),
   *     new Sprite(texture3)
   * ];
   *
   * container.addChild(...sprites);  // Add to scene graph
   * layer.attach(...sprites);       // Add to render layer
   *
   * // Later, remove all sprites from layer at once
   * layer.detachAll();
   * console.log(layer.renderLayerChildren.length); // 0
   * console.log(container.children.length);        // 3 (still in scene graph)
   * ```
   * @returns The RenderLayer instance for method chaining
   * @see {@link RenderLayer#attach} For adding objects to the layer
   * @see {@link RenderLayer#detach} For removing individual objects
   * @see {@link Container#removeChildren} For removing from scene graph
   */
  detachAll() {
    const layerChildren = this.renderLayerChildren;
    for (let i = 0; i < layerChildren.length; i++) {
      layerChildren[i].parentRenderLayer = null;
    }
    this.renderLayerChildren.length = 0;
  }
  /**
   * Collects renderables for this layer and its children.
   * This method is called by the renderer to gather all objects that should be rendered in this layer.
   * @param instructionSet - The set of instructions to collect renderables into.
   * @param renderer - The renderer that is collecting renderables.
   * @param _currentLayer - The current render layer being processed.
   * @internal
   */
  collectRenderables(instructionSet, renderer, _currentLayer) {
    const layerChildren = this.renderLayerChildren;
    const length = layerChildren.length;
    if (this.sortableChildren) {
      this.sortRenderLayerChildren();
    }
    for (let i = 0; i < length; i++) {
      if (!layerChildren[i].parent) {
        warn(
          "Container must be added to both layer and scene graph. Layers only handle render order - the scene graph is required for transforms (addChild)",
          layerChildren[i]
        );
      }
      layerChildren[i].collectRenderables(instructionSet, renderer, this);
    }
  }
  /**
   * Sort the layer's children using the defined sort function. This method allows manual sorting
   * of layer children and is automatically called during rendering if sortableChildren is true.
   * @example
   * ```ts
   * const layer = new RenderLayer();
   *
   * // Add multiple sprites at different depths
   * const sprite1 = new Sprite(texture);
   * const sprite2 = new Sprite(texture);
   * const sprite3 = new Sprite(texture);
   *
   * sprite1.zIndex = 3;
   * sprite2.zIndex = 1;
   * sprite3.zIndex = 2;
   *
   * layer.attach(sprite1, sprite2, sprite3);
   *
   * // Manual sorting with default zIndex sort
   * layer.sortRenderLayerChildren();
   * // Order is now: sprite2 (1), sprite3 (2), sprite1 (3)
   *
   * // Custom sort by y position
   * layer.sortFunction = (a, b) => a.y - b.y;
   * layer.sortRenderLayerChildren();
   *
   * // Automatic sorting
   * layer.sortableChildren = true; // Will sort each render
   * ```
   * @returns The RenderLayer instance for method chaining
   * @see {@link RenderLayer#sortableChildren} For enabling automatic sorting
   * @see {@link RenderLayer#sortFunction} For customizing the sort logic
   */
  sortRenderLayerChildren() {
    this.renderLayerChildren.sort(this.sortFunction);
  }
  /**
   * Recursively calculates the global bounds of this RenderLayer and its children.
   * @param factorRenderLayers
   * @param bounds
   * @param _currentLayer
   * @internal
   */
  _getGlobalBoundsRecursive(factorRenderLayers, bounds, _currentLayer) {
    if (!factorRenderLayers) return;
    const children = this.renderLayerChildren;
    for (let i = 0; i < children.length; i++) {
      children[i]._getGlobalBoundsRecursive(true, bounds, this);
    }
  }
  /**
   * @inheritdoc
   * @internal
   */
  getFastGlobalBounds(factorRenderLayers, bounds) {
    return super.getFastGlobalBounds(factorRenderLayers, bounds);
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error. Please use `RenderLayer.attach()` instead.
   * @param {...any} _children
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  addChild(..._children) {
    throw new Error(
      "RenderLayer.addChild() is not available. Please use RenderLayer.attach()"
    );
  }
  /**
   * This method is not available in RenderLayer.
   * Calling this method will throw an error. Please use `RenderLayer.detach()` instead.
   * @param {...any} _children
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  removeChild(..._children) {
    throw new Error(
      "RenderLayer.removeChild() is not available. Please use RenderLayer.detach()"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error. Please use `RenderLayer.detach()` instead.
   * @param {number} [_beginIndex]
   * @param {number} [_endIndex]
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  removeChildren(_beginIndex, _endIndex) {
    throw new Error(
      "RenderLayer.removeChildren() is not available. Please use RenderLayer.detach()"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  removeChildAt(_index) {
    throw new Error(
      "RenderLayer.removeChildAt() is not available"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  getChildAt(_index) {
    throw new Error(
      "RenderLayer.getChildAt() is not available"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param {Container} _child
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  setChildIndex(_child, _index) {
    throw new Error(
      "RenderLayer.setChildIndex() is not available"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param {Container} _child
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  getChildIndex(_child) {
    throw new Error(
      "RenderLayer.getChildIndex() is not available"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param {Container} _child
   * @param {number} _index
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  addChildAt(_child, _index) {
    throw new Error(
      "RenderLayer.addChildAt() is not available"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param {Container} _child
   * @param {Container} _child2
   * @ignore
   */
  swapChildren(_child, _child2) {
    throw new Error(
      "RenderLayer.swapChildren() is not available"
    );
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param _child - The child to reparent
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  reparentChild(..._child) {
    throw new Error("RenderLayer.reparentChild() is not available with the render layer");
  }
  /**
   * This method is not available in RenderLayer.
   *
   * Calling this method will throw an error.
   * @param _child - The child to reparent
   * @param _index - The index to reparent the child to
   * @throws {Error} Always throws an error as this method is not available.
   * @ignore
   */
  reparentChildAt(_child, _index) {
    throw new Error("RenderLayer.reparentChildAt() is not available with the render layer");
  }
};
/**
 * Default options for RenderLayer instances. These options control the sorting behavior
 * of objects within the render layer.
 * @example
 * ```ts
 * // Create a custom render layer with modified default options
 * RenderLayer.defaultOptions = {
 *     sortableChildren: true,
 *     sortFunction: (a, b) => a.y - b.y // Sort by vertical position
 * };
 *
 * // All new render layers will use these defaults
 * const layer1 = new RenderLayer();
 * // layer1 will have sortableChildren = true
 * ```
 * @property {boolean} sortableChildren -
 * @property {Function} sortFunction -
 * @see {@link RenderLayer} For the main render layer class
 * @see {@link Container#zIndex} For the default sort property
 * @see {@link RenderLayer#sortRenderLayerChildren} For manual sorting
 */
_RenderLayer.defaultOptions = {
  /** If true, layer children will be automatically sorted each render. Default is false. */
  sortableChildren: false,
  /**
   * Function used to sort layer children.
   * Default sorts by zIndex. Accepts two Container objects and returns
   * a number indicating their relative order.
   * @param a - First container to compare
   * @param b - Second container to compare
   * @returns Negative if a should render before b, positive if b should render before a
   */
  sortFunction: (a, b) => a.zIndex - b.zIndex
};
let RenderLayer = _RenderLayer;

export { RenderLayer };
//# sourceMappingURL=RenderLayer.mjs.map
