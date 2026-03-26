import EventEmitter from 'eventemitter3';
import { type ColorSource } from '../../color/Color';
import { Matrix } from '../../maths/matrix/Matrix';
import { ObservablePoint } from '../../maths/point/ObservablePoint';
import { type RenderLayer } from '../layers/RenderLayer';
import { RenderGroup } from './RenderGroup';
import type { Size } from '../../maths/misc/Size';
import type { PointData } from '../../maths/point/PointData';
import type { Rectangle } from '../../maths/shapes/Rectangle';
import type { BLEND_MODES } from '../../rendering/renderers/shared/state/const';
import type { Dict } from '../../utils/types';
import type { Optional } from './container-mixins/measureMixin';
import type { DestroyOptions } from './destroyTypes';
/**
 * The type of child that can be added to a {@link Container}.
 * This is a generic type that extends the {@link Container} class.
 * @category scene
 * @standard
 */
export type ContainerChild = Container;
/**
 * Events that can be emitted by a Container. These events provide lifecycle hooks and notifications
 * for container state changes.
 * @example
 * ```ts
 * import { Container, Sprite } from 'pixi.js';
 *
 * // Setup container with event listeners
 * const container = new Container();
 *
 * // Listen for child additions
 * container.on('childAdded', (child, container, index) => {
 *     console.log(`Child added at index ${index}:`, child);
 * });
 *
 * // Listen for child removals
 * container.on('childRemoved', (child, container, index) => {
 *     console.log(`Child removed from index ${index}:`, child);
 * });
 *
 * // Listen for when container is added to parent
 * container.on('added', (parent) => {
 *     console.log('Added to parent:', parent);
 * });
 *
 * // Listen for when container is removed from parent
 * container.on('removed', (parent) => {
 *     console.log('Removed from parent:', parent);
 * });
 *
 * // Listen for container destruction
 * container.on('destroyed', (container) => {
 *     console.log('Container destroyed:', container);
 * });
 * ```
 * @category scene
 * @standard
 */
export interface ContainerEvents<C extends ContainerChild> extends PixiMixins.ContainerEvents {
    /**
     * Emitted when this container is added to a new container.
     * Useful for setting up parent-specific behaviors.
     * @param container - The parent container this was added to
     * @example
     * ```ts
     * const child = new Container();
     * child.on('added', (parent) => {
     *     console.log('Child added to parent:', parent.label);
     * });
     * parentContainer.addChild(child);
     * ```
     */
    added: [container: Container];
    /**
     * Emitted when a child is added to this container.
     * Useful for tracking container composition changes.
     * @param child - The child that was added
     * @param container - The container the child was added to (this container)
     * @param index - The index at which the child was added
     * @example
     * ```ts
     * const parent = new Container();
     * parent.on('childAdded', (child, container, index) => {
     *     console.log(`New child at index ${index}:`, child);
     * });
     * ```
     */
    childAdded: [child: C, container: Container, index: number];
    /**
     * Emitted when this container is removed from its parent.
     * Useful for cleanup and state management.
     * @param container - The parent container this was removed from
     * @example
     * ```ts
     * const child = new Container();
     * child.on('removed', (oldParent) => {
     *     console.log('Child removed from parent:', oldParent.label);
     * });
     * ```
     */
    removed: [container: Container];
    /**
     * Emitted when a child is removed from this container.
     * Useful for cleanup and maintaining container state.
     * @param child - The child that was removed
     * @param container - The container the child was removed from (this container)
     * @param index - The index from which the child was removed
     * @example
     * ```ts
     * const parent = new Container();
     * parent.on('childRemoved', (child, container, index) => {
     *     console.log(`Child removed from index ${index}:`, child);
     * });
     * ```
     */
    childRemoved: [child: C, container: Container, index: number];
    /**
     * Emitted when the container is destroyed.
     * Useful for final cleanup and resource management.
     * @param container - The container that was destroyed
     * @example
     * ```ts
     * const container = new Container();
     * container.on('destroyed', (container) => {
     *     console.log('Container destroyed:', container.label);
     * });
     * ```
     */
    destroyed: [container: Container];
    /**
     * Emitted when the visible property on the container is changed.
     * Useful for tracking visibility changes and triggering related behaviors.
     * @param visible - The new visibility state of the container
     * @example
     * ```ts
     * const container = new Container();
     * container.on('visibleChanged', (visible) => {
     *     console.log('Container visibility changed:', visible);
     * });
     * ```
     */
    visibleChanged: [visible: boolean];
}
type AnyEvent = {
    [K: ({} & string) | ({} & symbol)]: any;
};
/** @internal */
export declare const UPDATE_COLOR = 1;
/** @internal */
export declare const UPDATE_BLEND = 2;
/** @internal */
export declare const UPDATE_VISIBLE = 4;
/** @internal */
export declare const UPDATE_TRANSFORM = 8;
/**
 * Options for updating the transform of a container.
 * @category scene
 * @standard
 */
export interface UpdateTransformOptions {
    x: number;
    y: number;
    scaleX: number;
    scaleY: number;
    rotation: number;
    skewX: number;
    skewY: number;
    pivotX: number;
    pivotY: number;
    originX: number;
    originY: number;
}
/**
 * Constructor options used for `Container` instances.
 * ```js
 * const container = new Container({
 *    position: new Point(100, 200),
 *    scale: new Point(2, 2),
 *    rotation: Math.PI / 2,
 * });
 * ```
 * @category scene
 * @standard
 * @see Container
 */
export interface ContainerOptions<C extends ContainerChild = ContainerChild> extends PixiMixins.ContainerOptions {
    /** @see Container#isRenderGroup */
    isRenderGroup?: boolean;
    /**
     * The blend mode to be applied to the sprite. Controls how pixels are blended when rendering.
     *
     * Setting to 'normal' will reset to default blending.
     * > [!NOTE] More blend modes are available after importing the `pixi.js/advanced-blend-modes` sub-export.
     * @example
     * ```ts
     * // Basic blend modes
     * new Container({ blendMode: 'normal' }); // Default blending
     * new Container({ blendMode: 'add' });    // Additive blending
     * new Container({ blendMode: 'multiply' }); // Multiply colors
     * new Container({ blendMode: 'screen' }); // Screen blend
     * ```
     * @default 'normal'
     * @see {@link Container#alpha} For transparency
     * @see {@link Container#tint} For color adjustments
     */
    blendMode?: BLEND_MODES;
    /**
     * The tint applied to the sprite.
     *
     * This can be any valid {@link ColorSource}.
     * @example
     * ```ts
     * new Container({ tint: 0xff0000 }); // Red tint
     * new Container({ tint: 'blue' }); // Blue tint
     * new Container({ tint: '#00ff00' }); // Green tint
     * new Container({ tint: 'rgb(0,0,255)' }); // Blue tint
     * ```
     * @default 0xFFFFFF
     * @see {@link Container#alpha} For transparency
     * @see {@link Container#visible} For visibility control
     */
    tint?: ColorSource;
    /**
     * The opacity of the object relative to its parent's opacity.
     * Value ranges from 0 (fully transparent) to 1 (fully opaque).
     * @example
     * ```ts
     * new Container({ alpha: 0.5 }); // 50% opacity
     * new Container({ alpha: 1 }); // Fully opaque
     * ```
     * @default 1
     * @see {@link Container#visible} For toggling visibility
     * @see {@link Container#renderable} For render control
     */
    alpha?: number;
    /**
     * The angle of the object in degrees.
     *
     * > [!NOTE] 'rotation' and 'angle' have the same effect on a display object;
     * > rotation is in radians, angle is in degrees.
     * @example
     * ```ts
     * new Container({ angle: 45 }); // Rotate 45 degrees
     * new Container({ angle: 90 }); // Rotate 90 degrees
     * ```
     */
    angle?: number;
    /**
     * The array of children of this container. Each child must be a Container or extend from it.
     *
     * The array is read-only, but its contents can be modified using Container methods.
     * @example
     * ```ts
     * new Container({
     *    children: [
     *        new Container(), // First child
     *        new Container(), // Second child
     *    ],
     * });
     * ```
     * @readonly
     * @see {@link Container#addChild} For adding children
     * @see {@link Container#removeChild} For removing children
     */
    children?: C[];
    /**
     * The display object container that contains this display object.
     * This represents the parent-child relationship in the display tree.
     * @readonly
     * @see {@link Container#addChild} For adding to a parent
     * @see {@link Container#removeChild} For removing from parent
     */
    parent?: Container;
    /**
     * Controls whether this object can be rendered. If false the object will not be drawn,
     * but the transform will still be updated. This is different from visible, which skips
     * transform updates.
     * @example
     * ```ts
     * new Container({ renderable: false }); // Will not be drawn, but transforms will update
     * ```
     * @default true
     * @see {@link Container#visible} For skipping transform updates
     * @see {@link Container#alpha} For transparency
     */
    renderable?: boolean;
    /**
     * The rotation of the object in radians.
     *
     * > [!NOTE] 'rotation' and 'angle' have the same effect on a display object;
     * > rotation is in radians, angle is in degrees.
     * @example
     * ```ts
     * new Container({ rotation: Math.PI / 4 }); // Rotate 45 degrees
     * new Container({ rotation: Math.PI / 2 }); // Rotate 90 degrees
     * ```
     */
    rotation?: number;
    /**
     * The scale factors of this object along the local coordinate axes.
     *
     * The default scale is (1, 1).
     * @example
     * ```ts
     * new Container({ scale: new Point(2, 2) }); // Scale by 2x
     * new Container({ scale: 0.5 }); // Scale by 0.5x
     * new Container({ scale: { x: 1.5, y: 1.5 } }); // Scale by 1.5x
     * ```
     */
    scale?: PointData | number;
    /**
     * The center of rotation, scaling, and skewing for this display object in its local space.
     * The `position` is the projection of `pivot` in the parent's local space.
     *
     * By default, the pivot is the origin (0, 0).
     * @example
     * ```ts
     * new Container({ pivot: new Point(100, 200) }); // Set pivot to (100, 200)
     * new Container({ pivot: 50 }); // Set pivot to (50, 50)
     * new Container({ pivot: { x: 150, y: 150 } }); // Set pivot to (150, 150)
     * ```
     */
    pivot?: PointData | number;
    /**
     * The origin point around which the container rotates and scales.
     * Unlike pivot, changing origin will not move the container's position.
     * @example
     * ```ts
     * new Container({ origin: new Point(100, 100) }); // Rotate around point (100,100)
     * new Container({ origin: 50 }); // Rotate around point (50, 50)
     * new Container({ origin: { x: 150, y: 150 } }); // Rotate around point (150, 150)
     * ```
     */
    origin?: PointData | number;
    /**
     * The coordinate of the object relative to the local coordinates of the parent.
     * @example
     * ```ts
     * new Container({ position: new Point(100, 200) }); // Set position to (100, 200)
     * new Container({ position: { x: 150, y: 150 } }); // Set position to (150, 150)
     * ```
     */
    position?: PointData;
    /**
     * The skew factor for the object in radians. Skewing is a transformation that distorts
     * the object by rotating it differently at each point, creating a non-uniform shape.
     * @example
     * ```ts
     * new Container({ skew: new Point(0.1, 0.2) }); // Skew by 0.1 radians on x and 0.2 radians on y
     * new Container({ skew: { x: 0.1, y: 0.2 } }); // Skew by 0.1 radians on x and 0.2 radians on y
     * ```
     * @default { x: 0, y: 0 }
     */
    skew?: PointData;
    /**
     * The visibility of the object. If false the object will not be drawn,
     * and the transform will not be updated.
     * @example
     * ```ts
     * new Container({ visible: false }); // Will not be drawn and transforms will not update
     * new Container({ visible: true }); // Will be drawn and transforms will update
     * ```
     * @default true
     * @see {@link Container#renderable} For render-only control
     * @see {@link Container#alpha} For transparency
     */
    visible?: boolean;
    /**
     * The position of the container on the x axis relative to the local coordinates of the parent.
     *
     * An alias to position.x
     * @example
     * ```ts
     * new Container({ x: 100 }); // Set x position to 100
     * ```
     */
    x?: number;
    /**
     * The position of the container on the y axis relative to the local coordinates of the parent.
     *
     * An alias to position.y
     * @example
     * ```ts
     * new Container({ y: 200 }); // Set y position to 200
     * ```
     */
    y?: number;
    /**
     * An optional bounds area for this container. Setting this rectangle will stop the renderer
     * from recursively measuring the bounds of each children and instead use this single boundArea.
     *
     * > [!IMPORTANT] This is great for optimisation! If for example you have a
     * > 1000 spinning particles and you know they all sit within a specific bounds,
     * > then setting it will mean the renderer will not need to measure the
     * > 1000 children to find the bounds. Instead it will just use the bounds you set.
     * @example
     * ```ts
     * const container = new Container({
     *    boundsArea: new Rectangle(0, 0, 500, 500) // Set a fixed bounds area
     * });
     * ```
     */
    boundsArea?: Rectangle;
}
export interface Container<C extends ContainerChild> extends PixiMixins.Container<C>, EventEmitter<ContainerEvents<C> & AnyEvent> {
}
/**
 * Container is a general-purpose display object that holds children. It also adds built-in support for advanced
 * rendering features like masking and filtering.
 *
 * It is the base class of all display objects that act as a container for other objects, including Graphics
 * and Sprite.
 *
 * <details id="transforms">
 *
 * <summary>Transforms</summary>
 *
 * The [transform]{@link Container#localTransform} of a display object describes the projection from its
 * local coordinate space to its parent's local coordinate space. The following properties are derived
 * from the transform:
 *
 * <table>
 *   <thead>
 *     <tr>
 *       <th>Property</th>
 *       <th>Description</th>
 *     </tr>
 *   </thead>
 *   <tbody>
 *     <tr>
 *       <td>[pivot]{@link Container#pivot}</td>
 *       <td>
 *         Invariant under rotation, scaling, and skewing. The projection of into the parent's space of the pivot
 *         is equal to position, regardless of the other three transformations. In other words, It is the center of
 *         rotation, scaling, and skewing.
 *       </td>
 *     </tr>
 *     <tr>
 *       <td>[position]{@link Container#position}</td>
 *       <td>
 *         Translation. This is the position of the [pivot]{@link Container#pivot} in the parent's local
 *         space. The default value of the pivot is the origin (0,0). If the top-left corner of your display object
 *         is (0,0) in its local space, then the position will be its top-left corner in the parent's local space.
 *       </td>
 *     </tr>
 *     <tr>
 *       <td>[scale]{@link Container#scale}</td>
 *       <td>
 *         Scaling. This will stretch (or compress) the display object's projection. The scale factors are along the
 *         local coordinate axes. In other words, the display object is scaled before rotated or skewed. The center
 *         of scaling is the [pivot]{@link Container#pivot}.
 *       </td>
 *     </tr>
 *     <tr>
 *       <td>[rotation]{@link Container#rotation}</td>
 *       <td>
 *          Rotation. This will rotate the display object's projection by this angle (in radians).
 *       </td>
 *     </tr>
 *     <tr>
 *       <td>[skew]{@link Container#skew}</td>
 *       <td>
 *         <p>Skewing. This can be used to deform a rectangular display object into a parallelogram.</p>
 *         <p>
 *         In PixiJS, skew has a slightly different behaviour than the conventional meaning. It can be
 *         thought of the net rotation applied to the coordinate axes (separately). For example, if "skew.x" is
 *         ⍺ and "skew.y" is β, then the line x = 0 will be rotated by ⍺ (y = -x*cot⍺) and the line y = 0 will be
 *         rotated by β (y = x*tanβ). A line y = x*tanϴ (i.e. a line at angle ϴ to the x-axis in local-space) will
 *         be rotated by an angle between ⍺ and β.
 *         </p>
 *         <p>
 *         It can be observed that if skew is applied equally to both axes, then it will be equivalent to applying
 *         a rotation. Indeed, if "skew.x" = -ϴ and "skew.y" = ϴ, it will produce an equivalent of "rotation" = ϴ.
 *         </p>
 *         <p>
 *         Another quite interesting observation is that "skew.x", "skew.y", rotation are commutative operations. Indeed,
 *         because rotation is essentially a careful combination of the two.
 *         </p>
 *       </td>
 *     </tr>
 *     <tr>
 *       <td>[angle]{@link Container#angle}</td>
 *       <td>Rotation. This is an alias for [rotation]{@link Container#rotation}, but in degrees.</td>
 *     </tr>
 *     <tr>
 *       <td>[x]{@link Container#x}</td>
 *       <td>Translation. This is an alias for position.x!</td>
 *     </tr>
 *     <tr>
 *       <td>[y]{@link Container#y}</td>
 *       <td>Translation. This is an alias for position.y!</td>
 *     </tr>
 *     <tr>
 *       <td>[width]{@link Container#width}</td>
 *       <td>
 *         Implemented in [Container]{@link Container}. Scaling. The width property calculates scale.x by dividing
 *         the "requested" width by the local bounding box width. It is indirectly an abstraction over scale.x, and there
 *         is no concept of user-defined width.
 *       </td>
 *     </tr>
 *     <tr>
 *       <td>[height]{@link Container#height}</td>
 *       <td>
 *         Implemented in [Container]{@link Container}. Scaling. The height property calculates scale.y by dividing
 *         the "requested" height by the local bounding box height. It is indirectly an abstraction over scale.y, and there
 *         is no concept of user-defined height.
 *       </td>
 *     </tr>
 *   </tbody>
 * </table>
 * </details>
 *
 * <details id="alpha">
 * <summary>Alpha</summary>
 *
 * This alpha sets a display object's **relative opacity** w.r.t its parent. For example, if the alpha of a display
 * object is 0.5 and its parent's alpha is 0.5, then it will be rendered with 25% opacity (assuming alpha is not
 * applied on any ancestor further up the chain).
 * </details>
 *
 * <details id="visible">
 * <summary>Renderable vs Visible</summary>
 *
 * The `renderable` and `visible` properties can be used to prevent a display object from being rendered to the
 * screen. However, there is a subtle difference between the two. When using `renderable`, the transforms  of the display
 * object (and its children subtree) will continue to be calculated. When using `visible`, the transforms will not
 * be calculated.
 * ```ts
 * import { BlurFilter, Container, Graphics, Sprite } from 'pixi.js';
 *
 * const container = new Container();
 * const sprite = Sprite.from('https://s3-us-west-2.amazonaws.com/s.cdpn.io/693612/IaUrttj.png');
 *
 * sprite.width = 512;
 * sprite.height = 512;
 *
 * // Adds a sprite as a child to this container. As a result, the sprite will be rendered whenever the container
 * // is rendered.
 * container.addChild(sprite);
 *
 * // Blurs whatever is rendered by the container
 * container.filters = [new BlurFilter()];
 *
 * // Only the contents within a circle at the center should be rendered onto the screen.
 * container.mask = new Graphics()
 *     .beginFill(0xffffff)
 *     .drawCircle(sprite.width / 2, sprite.height / 2, Math.min(sprite.width, sprite.height) / 2)
 *     .endFill();
 * ```
 *
 * </details>
 *
 * <details id="renderGroup">
 * <summary>RenderGroup</summary>
 *
 * In PixiJS v8, containers can be set to operate in 'render group mode',
 * transforming them into entities akin to a stage in traditional rendering paradigms.
 * A render group is a root renderable entity, similar to a container,
 * but it's rendered in a separate pass with its own unique set of rendering instructions.
 * This approach enhances rendering efficiency and organization, particularly in complex scenes.
 *
 * You can enable render group mode on any container using container.enableRenderGroup()
 * or by initializing a new container with the render group property set to true (new Container({isRenderGroup: true})).
 *  The method you choose depends on your specific use case and setup requirements.
 *
 * An important aspect of PixiJS’s rendering process is the automatic treatment of rendered scenes as render groups.
 * This conversion streamlines the rendering process, but understanding when and how this happens is crucial
 * to fully leverage its benefits.
 *
 * One of the key advantages of using render groups is the performance efficiency in moving them. Since transformations
 *  are applied at the GPU level, moving a render group, even one with complex and numerous children,
 * doesn't require recalculating the rendering instructions or performing transformations on each child.
 * This makes operations like panning a large game world incredibly efficient.
 *
 * However, it's crucial to note that render groups do not batch together.
 * This means that turning every container into a render group could actually slow things down,
 * as each render group is processed separately. It's best to use render groups judiciously, at a broader level,
 * rather than on a per-child basis.
 * This approach ensures you get the performance benefits without overburdening the rendering process.
 *
 * RenderGroups maintain their own set of rendering instructions,
 * ensuring that changes or updates within a render group don't affect the rendering
 * instructions of its parent or other render groups.
 *  This isolation ensures more stable and predictable rendering behavior.
 *
 * Additionally, renderGroups can be nested, allowing for powerful options in organizing different aspects of your scene.
 * This feature is particularly beneficial for separating complex game graphics from UI elements,
 * enabling intricate and efficient scene management in complex applications.
 *
 * This means that Containers have 3 levels of matrix to be mindful of:
 *
 * 1. localTransform, this is the transform of the container based on its own properties
 * 2. groupTransform, this it the transform of the container relative to the renderGroup it belongs too
 * 3. worldTransform, this is the transform of the container relative to the Scene being rendered
 * </details>
 * @category scene
 * @standard
 */
export declare class Container<C extends ContainerChild = ContainerChild> extends EventEmitter<ContainerEvents<C> & AnyEvent> {
    /**
     * Mixes all enumerable properties and methods from a source object to Container.
     * @param source - The source of properties and methods to mix in.
     * @deprecated since 8.8.0
     */
    static mixin(source: Dict<any>): void;
    /**
     * unique id for this container
     * @internal
     */
    readonly uid: number;
    /** @private */
    _updateFlags: number;
    /** @private */
    renderGroup: RenderGroup;
    /** @private */
    parentRenderGroup: RenderGroup;
    /** @private */
    parentRenderGroupIndex: number;
    /** @private */
    didChange: boolean;
    /** @private */
    didViewUpdate: boolean;
    /** @private */
    relativeRenderGroupDepth: number;
    /**
     * The array of children of this container. Each child must be a Container or extend from it.
     *
     * The array is read-only, but its contents can be modified using Container methods.
     * @example
     * ```ts
     * // Access children
     * const firstChild = container.children[0];
     * const lastChild = container.children[container.children.length - 1];
     * ```
     * @readonly
     * @see {@link Container#addChild} For adding children
     * @see {@link Container#removeChild} For removing children
     */
    children: C[];
    /**
     * The display object container that contains this display object.
     * This represents the parent-child relationship in the display tree.
     * @example
     * ```ts
     * // Basic parent access
     * const parent = sprite.parent;
     *
     * // Walk up the tree
     * let current = sprite;
     * while (current.parent) {
     *     console.log('Level up:', current.parent.constructor.name);
     *     current = current.parent;
     * }
     * ```
     * @readonly
     * @see {@link Container#addChild} For adding to a parent
     * @see {@link Container#removeChild} For removing from parent
     */
    parent: Container | null;
    /** @private */
    includeInBuild: boolean;
    /** @private */
    measurable: boolean;
    /** @private */
    isSimple: boolean;
    /**
     * The RenderLayer this container belongs to, if any.
     * If it belongs to a RenderLayer, it will be rendered from the RenderLayer's position in the scene.
     * @readonly
     * @advanced
     */
    parentRenderLayer: RenderLayer | null;
    /** @internal */
    updateTick: number;
    /**
     * Current transform of the object based on local factors: position, scale, other stuff.
     * This matrix represents the local transformation without any parent influence.
     * @example
     * ```ts
     * // Basic transform access
     * const localMatrix = sprite.localTransform;
     * console.log(localMatrix.toString());
     * ```
     * @readonly
     * @see {@link Container#worldTransform} For global transform
     * @see {@link Container#groupTransform} For render group transform
     */
    localTransform: Matrix;
    /**
     * The relative group transform is a transform relative to the render group it belongs too. It will include all parent
     * transforms and up to the render group (think of it as kind of like a stage - but the stage can be nested).
     * If this container is is self a render group matrix will be relative to its parent render group
     * @readonly
     * @advanced
     */
    relativeGroupTransform: Matrix;
    /**
     * The group transform is a transform relative to the render group it belongs too.
     * If this container is render group then this will be an identity matrix. other wise it
     * will be the same as the relativeGroupTransform.
     * Use this value when actually rendering things to the screen
     * @readonly
     * @advanced
     */
    groupTransform: Matrix;
    private _worldTransform;
    /**
     * Whether this object has been destroyed. If true, the object should no longer be used.
     * After an object is destroyed, all of its functionality is disabled and references are removed.
     * @example
     * ```ts
     * // Cleanup with destroy
     * sprite.destroy();
     * console.log(sprite.destroyed); // true
     * ```
     * @default false
     * @see {@link Container#destroy} For destroying objects
     */
    destroyed: boolean;
    /**
     * The coordinate of the object relative to the local coordinates of the parent.
     * @internal
     */
    _position: ObservablePoint;
    /**
     * The scale factor of the object.
     * @internal
     */
    _scale: ObservablePoint;
    /**
     * The pivot point of the container that it rotates around.
     * @internal
     */
    _pivot: ObservablePoint;
    /**
     * The origin point around which the container rotates and scales.
     * Unlike pivot, changing origin will not move the container's position.
     * @private
     */
    _origin: ObservablePoint;
    /**
     * The skew amount, on the x and y axis.
     * @internal
     */
    _skew: ObservablePoint;
    /**
     * The X-coordinate value of the normalized local X axis,
     * the first column of the local transformation matrix without a scale.
     * @internal
     */
    _cx: number;
    /**
     * The Y-coordinate value of the normalized local X axis,
     * the first column of the local transformation matrix without a scale.
     * @internal
     */
    _sx: number;
    /**
     * The X-coordinate value of the normalized local Y axis,
     * the second column of the local transformation matrix without a scale.
     * @internal
     */
    _cy: number;
    /**
     * The Y-coordinate value of the normalized local Y axis,
     * the second column of the local transformation matrix without a scale.
     * @internal
     */
    _sy: number;
    /**
     * The rotation amount.
     * @internal
     */
    private _rotation;
    /** @internal */
    localColor: number;
    /** @internal */
    localAlpha: number;
    /** @internal */
    groupAlpha: number;
    /** @internal */
    groupColor: number;
    /** @internal */
    groupColorAlpha: number;
    /** @internal */
    localBlendMode: BLEND_MODES;
    /** @internal */
    groupBlendMode: BLEND_MODES;
    /**
     * This property holds three bits: culled, visible, renderable
     * the third bit represents culling (0 = culled, 1 = not culled) 0b100
     * the second bit represents visibility (0 = not visible, 1 = visible) 0b010
     * the first bit represents renderable (0 = not renderable, 1 = renderable) 0b001
     * @internal
     */
    localDisplayStatus: number;
    /** @internal */
    globalDisplayStatus: number;
    /** @internal */
    readonly renderPipeId: string;
    /**
     * An optional bounds area for this container. Setting this rectangle will stop the renderer
     * from recursively measuring the bounds of each children and instead use this single boundArea.
     *
     * > [!IMPORTANT] This is great for optimisation! If for example you have a
     * > 1000 spinning particles and you know they all sit within a specific bounds,
     * > then setting it will mean the renderer will not need to measure the
     * > 1000 children to find the bounds. Instead it will just use the bounds you set.
     * @example
     * ```ts
     * const container = new Container();
     * container.boundsArea = new Rectangle(0, 0, 500, 500);
     * ```
     */
    boundsArea: Rectangle;
    /**
     * A value that increments each time the containe is modified
     * eg children added, removed etc
     * @ignore
     */
    _didContainerChangeTick: number;
    /**
     * A value that increments each time the container view is modified
     * eg texture swap, geometry change etc
     * @ignore
     */
    _didViewChangeTick: number;
    /** @internal */
    layerParentId: string;
    /**
     * We now use the _didContainerChangeTick and _didViewChangeTick to track changes
     * @deprecated since 8.2.6
     * @ignore
     */
    set _didChangeId(value: number);
    /** @ignore */
    get _didChangeId(): number;
    /**
     * property that tracks if the container transform has changed
     * @ignore
     */
    private _didLocalTransformChangeId;
    constructor(options?: ContainerOptions<C>);
    /**
     * Adds one or more children to the container.
     * The children will be rendered as part of this container's display list.
     * @example
     * ```ts
     * // Add a single child
     * container.addChild(sprite);
     *
     * // Add multiple children
     * container.addChild(background, player, foreground);
     *
     * // Add with type checking
     * const sprite = container.addChild<Sprite>(new Sprite(texture));
     * sprite.tint = 'red';
     * ```
     * @param children - The Container(s) to add to the container
     * @returns The first child that was added
     * @see {@link Container#removeChild} For removing children
     * @see {@link Container#addChildAt} For adding at specific index
     */
    addChild<U extends C[]>(...children: U): U[0];
    /**
     * Removes one or more children from the container.
     * When removing multiple children, events will be triggered for each child in sequence.
     * @example
     * ```ts
     * // Remove a single child
     * const removed = container.removeChild(sprite);
     *
     * // Remove multiple children
     * const bg = container.removeChild(background, player, userInterface);
     *
     * // Remove with type checking
     * const sprite = container.removeChild<Sprite>(childSprite);
     * sprite.texture = newTexture;
     * ```
     * @param children - The Container(s) to remove
     * @returns The first child that was removed
     * @see {@link Container#addChild} For adding children
     * @see {@link Container#removeChildren} For removing multiple children
     */
    removeChild<U extends C[]>(...children: U): U[0];
    /** @ignore */
    _onUpdate(point?: ObservablePoint): void;
    set isRenderGroup(value: boolean);
    /**
     * Returns true if this container is a render group.
     * This means that it will be rendered as a separate pass, with its own set of instructions
     * @advanced
     */
    get isRenderGroup(): boolean;
    /**
     * Calling this enables a render group for this container.
     * This means it will be rendered as a separate set of instructions.
     * The transform of the container will also be handled on the GPU rather than the CPU.
     * @advanced
     */
    enableRenderGroup(): void;
    /**
     * This will disable the render group for this container.
     * @advanced
     */
    disableRenderGroup(): void;
    /** @ignore */
    _updateIsSimple(): void;
    /**
     * Current transform of the object based on world (parent) factors.
     *
     * This matrix represents the absolute transformation in the scene graph.
     * @example
     * ```ts
     * // Get world position
     * const worldPos = container.worldTransform;
     * console.log(`World position: (${worldPos.tx}, ${worldPos.ty})`);
     * ```
     * @readonly
     * @see {@link Container#localTransform} For local space transform
     */
    get worldTransform(): Matrix;
    /**
     * The position of the container on the x axis relative to the local coordinates of the parent.
     *
     * An alias to position.x
     * @example
     * ```ts
     * // Basic position
     * container.x = 100;
     * ```
     */
    get x(): number;
    set x(value: number);
    /**
     * The position of the container on the y axis relative to the local coordinates of the parent.
     *
     * An alias to position.y
     * @example
     * ```ts
     * // Basic position
     * container.y = 200;
     * ```
     */
    get y(): number;
    set y(value: number);
    /**
     * The coordinate of the object relative to the local coordinates of the parent.
     * @example
     * ```ts
     * // Basic position setting
     * container.position.set(100, 200);
     * container.position.set(100); // Sets both x and y to 100
     * // Using point data
     * container.position = { x: 50, y: 75 };
     * ```
     * @since 4.0.0
     */
    get position(): ObservablePoint;
    set position(value: PointData);
    /**
     * The rotation of the object in radians.
     *
     * > [!NOTE] 'rotation' and 'angle' have the same effect on a display object;
     * > rotation is in radians, angle is in degrees.
     * @example
     * ```ts
     * // Basic rotation
     * container.rotation = Math.PI / 4; // 45 degrees
     *
     * // Convert from degrees
     * const degrees = 45;
     * container.rotation = degrees * Math.PI / 180;
     *
     * // Rotate around center
     * container.pivot.set(container.width / 2, container.height / 2);
     * container.rotation = Math.PI; // 180 degrees
     *
     * // Rotate around center with origin
     * container.origin.set(container.width / 2, container.height / 2);
     * container.rotation = Math.PI; // 180 degrees
     * ```
     */
    get rotation(): number;
    set rotation(value: number);
    /**
     * The angle of the object in degrees.
     *
     * > [!NOTE] 'rotation' and 'angle' have the same effect on a display object;
     * > rotation is in radians, angle is in degrees.
     * @example
     * ```ts
     * // Basic angle rotation
     * sprite.angle = 45; // 45 degrees
     *
     * // Rotate around center
     * sprite.pivot.set(sprite.width / 2, sprite.height / 2);
     * sprite.angle = 180; // Half rotation
     *
     * // Rotate around center with origin
     * sprite.origin.set(sprite.width / 2, sprite.height / 2);
     * sprite.angle = 180; // Half rotation
     *
     * // Reset rotation
     * sprite.angle = 0;
     * ```
     */
    get angle(): number;
    set angle(value: number);
    /**
     * The center of rotation, scaling, and skewing for this display object in its local space.
     * The `position` is the projection of `pivot` in the parent's local space.
     *
     * By default, the pivot is the origin (0, 0).
     * @example
     * ```ts
     * // Rotate around center
     * container.pivot.set(container.width / 2, container.height / 2);
     * container.rotation = Math.PI; // Rotates around center
     * ```
     * @since 4.0.0
     */
    get pivot(): ObservablePoint;
    set pivot(value: PointData | number);
    /**
     * The skew factor for the object in radians. Skewing is a transformation that distorts
     * the object by rotating it differently at each point, creating a non-uniform shape.
     * @example
     * ```ts
     * // Basic skewing
     * container.skew.set(0.5, 0); // Skew horizontally
     * container.skew.set(0, 0.5); // Skew vertically
     *
     * // Skew with point data
     * container.skew = { x: 0.3, y: 0.3 }; // Diagonal skew
     *
     * // Reset skew
     * container.skew.set(0, 0);
     *
     * // Animate skew
     * app.ticker.add(() => {
     *     // Create wave effect
     *     container.skew.x = Math.sin(Date.now() / 1000) * 0.3;
     * });
     *
     * // Combine with rotation
     * container.rotation = Math.PI / 4; // 45 degrees
     * container.skew.set(0.2, 0.2); // Skew the rotated object
     * ```
     * @since 4.0.0
     * @type {ObservablePoint} Point-like object with x/y properties in radians
     * @default {x: 0, y: 0}
     */
    get skew(): ObservablePoint;
    set skew(value: PointData);
    /**
     * The scale factors of this object along the local coordinate axes.
     *
     * The default scale is (1, 1).
     * @example
     * ```ts
     * // Basic scaling
     * container.scale.set(2, 2); // Scales to double size
     * container.scale.set(2); // Scales uniformly to double size
     * container.scale = 2; // Scales uniformly to double size
     * // Scale to a specific width and height
     * container.setSize(200, 100); // Sets width to 200 and height to 100
     * ```
     * @since 4.0.0
     */
    get scale(): ObservablePoint;
    set scale(value: PointData | number | string);
    /**
     * @experimental
     * The origin point around which the container rotates and scales without affecting its position.
     * Unlike pivot, changing the origin will not move the container's position.
     * @example
     * ```ts
     * // Rotate around center point
     * container.origin.set(container.width / 2, container.height / 2);
     * container.rotation = Math.PI; // Rotates around center
     *
     * // Reset origin
     * container.origin.set(0, 0);
     * ```
     */
    get origin(): ObservablePoint;
    set origin(value: PointData | number);
    /**
     * The width of the Container, setting this will actually modify the scale to achieve the value set.
     * > [!NOTE] Changing the width will adjust the scale.x property of the container while maintaining its aspect ratio.
     * > [!NOTE] If you want to set both width and height at the same time, use {@link Container#setSize}
     * as it is more optimized by not recalculating the local bounds twice.
     * @example
     * ```ts
     * // Basic width setting
     * container.width = 100;
     * // Optimized width setting
     * container.setSize(100, 100);
     * ```
     */
    get width(): number;
    set width(value: number);
    /**
     * The height of the Container,
     * > [!NOTE] Changing the height will adjust the scale.y property of the container while maintaining its aspect ratio.
     * > [!NOTE] If you want to set both width and height at the same time, use {@link Container#setSize}
     * as it is more optimized by not recalculating the local bounds twice.
     * @example
     * ```ts
     * // Basic height setting
     * container.height = 200;
     * // Optimized height setting
     * container.setSize(100, 200);
     * ```
     */
    get height(): number;
    set height(value: number);
    /**
     * Retrieves the size of the container as a [Size]{@link Size} object.
     *
     * This is faster than get the width and height separately.
     * @example
     * ```ts
     * // Basic size retrieval
     * const size = container.getSize();
     * console.log(`Size: ${size.width}x${size.height}`);
     *
     * // Reuse existing size object
     * const reuseSize = { width: 0, height: 0 };
     * container.getSize(reuseSize);
     * ```
     * @param out - Optional object to store the size in.
     * @returns The size of the container.
     */
    getSize(out?: Size): Size;
    /**
     * Sets the size of the container to the specified width and height.
     * This is more efficient than setting width and height separately as it only recalculates bounds once.
     * @example
     * ```ts
     * // Basic size setting
     * container.setSize(100, 200);
     *
     * // Set uniform size
     * container.setSize(100); // Sets both width and height to 100
     * ```
     * @param value - This can be either a number or a [Size]{@link Size} object.
     * @param height - The height to set. Defaults to the value of `width` if not provided.
     */
    setSize(value: number | Optional<Size, 'height'>, height?: number): void;
    /** Called when the skew or the rotation changes. */
    private _updateSkew;
    /**
     * Updates the transform properties of the container.
     * Allows partial updates of transform properties for optimized manipulation.
     * @example
     * ```ts
     * // Basic transform update
     * container.updateTransform({
     *     x: 100,
     *     y: 200,
     *     rotation: Math.PI / 4
     * });
     *
     * // Scale and rotate around center
     * sprite.updateTransform({
     *     pivotX: sprite.width / 2,
     *     pivotY: sprite.height / 2,
     *     scaleX: 2,
     *     scaleY: 2,
     *     rotation: Math.PI
     * });
     *
     * // Update position only
     * button.updateTransform({
     *     x: button.x + 10, // Move right
     *     y: button.y      // Keep same y
     * });
     * ```
     * @param opts - Transform options to update
     * @param opts.x - The x position
     * @param opts.y - The y position
     * @param opts.scaleX - The x-axis scale factor
     * @param opts.scaleY - The y-axis scale factor
     * @param opts.rotation - The rotation in radians
     * @param opts.skewX - The x-axis skew factor
     * @param opts.skewY - The y-axis skew factor
     * @param opts.pivotX - The x-axis pivot point
     * @param opts.pivotY - The y-axis pivot point
     * @returns This container, for chaining
     * @see {@link Container#setFromMatrix} For matrix-based transforms
     * @see {@link Container#position} For direct position access
     */
    updateTransform(opts: Partial<UpdateTransformOptions>): this;
    /**
     * Updates the local transform properties by decomposing the given matrix.
     * Extracts position, scale, rotation, and skew from a transformation matrix.
     * @example
     * ```ts
     * // Basic matrix transform
     * const matrix = new Matrix()
     *     .translate(100, 100)
     *     .rotate(Math.PI / 4)
     *     .scale(2, 2);
     *
     * container.setFromMatrix(matrix);
     *
     * // Copy transform from another container
     * const source = new Container();
     * source.position.set(100, 100);
     * source.rotation = Math.PI / 2;
     *
     * target.setFromMatrix(source.localTransform);
     *
     * // Reset transform
     * container.setFromMatrix(Matrix.IDENTITY);
     * ```
     * @param matrix - The matrix to use for updating the transform
     * @see {@link Container#updateTransform} For property-based updates
     * @see {@link Matrix#decompose} For matrix decomposition details
     */
    setFromMatrix(matrix: Matrix): void;
    /** Updates the local transform. */
    updateLocalTransform(): void;
    set alpha(value: number);
    /**
     * The opacity of the object relative to its parent's opacity.
     * Value ranges from 0 (fully transparent) to 1 (fully opaque).
     * @example
     * ```ts
     * // Basic transparency
     * sprite.alpha = 0.5; // 50% opacity
     *
     * // Inherited opacity
     * container.alpha = 0.5;
     * const child = new Sprite(texture);
     * child.alpha = 0.5;
     * container.addChild(child);
     * // child's effective opacity is 0.25 (0.5 * 0.5)
     * ```
     * @default 1
     * @see {@link Container#visible} For toggling visibility
     * @see {@link Container#renderable} For render control
     */
    get alpha(): number;
    set tint(value: ColorSource);
    /**
     * The tint applied to the sprite.
     *
     * This can be any valid {@link ColorSource}.
     * @example
     * ```ts
     * // Basic color tinting
     * container.tint = 0xff0000; // Red tint
     * container.tint = 'red';    // Same as above
     * container.tint = '#00ff00'; // Green
     * container.tint = 'rgb(0,0,255)'; // Blue
     *
     * // Remove tint
     * container.tint = 0xffffff; // White = no tint
     * container.tint = null;     // Also removes tint
     * ```
     * @default 0xFFFFFF
     * @see {@link Container#alpha} For transparency
     * @see {@link Container#visible} For visibility control
     */
    get tint(): number;
    set blendMode(value: BLEND_MODES);
    /**
     * The blend mode to be applied to the sprite. Controls how pixels are blended when rendering.
     *
     * Setting to 'normal' will reset to default blending.
     * > [!NOTE] More blend modes are available after importing the `pixi.js/advanced-blend-modes` sub-export.
     * @example
     * ```ts
     * // Basic blend modes
     * sprite.blendMode = 'add';        // Additive blending
     * sprite.blendMode = 'multiply';   // Multiply colors
     * sprite.blendMode = 'screen';     // Screen blend
     *
     * // Reset blend mode
     * sprite.blendMode = 'normal';     // Normal blending
     * ```
     * @default 'normal'
     * @see {@link Container#alpha} For transparency
     * @see {@link Container#tint} For color adjustments
     */
    get blendMode(): BLEND_MODES;
    /**
     * The visibility of the object. If false the object will not be drawn,
     * and the transform will not be updated.
     * @example
     * ```ts
     * // Basic visibility toggle
     * sprite.visible = false; // Hide sprite
     * sprite.visible = true;  // Show sprite
     * ```
     * @default true
     * @see {@link Container#renderable} For render-only control
     * @see {@link Container#alpha} For transparency
     */
    get visible(): boolean;
    set visible(value: boolean);
    /** @ignore */
    get culled(): boolean;
    /** @ignore */
    set culled(value: boolean);
    /**
     * Controls whether this object can be rendered. If false the object will not be drawn,
     * but the transform will still be updated. This is different from visible, which skips
     * transform updates.
     * @example
     * ```ts
     * // Basic render control
     * sprite.renderable = false; // Skip rendering
     * sprite.renderable = true;  // Enable rendering
     * ```
     * @default true
     * @see {@link Container#visible} For skipping transform updates
     * @see {@link Container#alpha} For transparency
     */
    get renderable(): boolean;
    set renderable(value: boolean);
    /**
     * Whether or not the object should be rendered.
     * @advanced
     */
    get isRenderable(): boolean;
    /**
     * Removes all internal references and listeners as well as removes children from the display list.
     * Do not use a Container after calling `destroy`.
     * @param options - Options parameter. A boolean will act as if all options
     *  have been set to that value
     * @example
     * ```ts
     * container.destroy();
     * container.destroy(true);
     * container.destroy({ children: true });
     * container.destroy({ children: true, texture: true, textureSource: true });
     * ```
     */
    destroy(options?: DestroyOptions): void;
}
export {};
