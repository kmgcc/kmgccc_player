import { Matrix } from '../../maths/matrix/Matrix';
import { InstructionSet } from '../../rendering/renderers/shared/instructions/InstructionSet';
import { type SCALE_MODE } from '../../rendering/renderers/shared/texture/const';
import { type Renderer } from '../../rendering/renderers/types';
import type { Instruction } from '../../rendering/renderers/shared/instructions/Instruction';
import type { Texture } from '../../rendering/renderers/shared/texture/Texture';
import type { BatchableSprite } from '../sprite/BatchableSprite';
import type { ViewContainer } from '../view/ViewContainer';
import type { Bounds } from './bounds/Bounds';
import type { Container } from './Container';
/**
 * Options for caching a container as a texture.
 * @category rendering
 * @advanced
 */
export interface CacheAsTextureOptions {
    /**
     * If true, the texture will be antialiased. This smooths out the edges of the texture.
     * @default false
     */
    antialias?: boolean;
    /**
     * The resolution of the texture. A higher resolution means a sharper texture but uses more memory.
     * By default the resolution is 1 which is the same as the rendererers resolution.
     */
    resolution?: number;
    /**
     * Scale Mode to use for the cached texture
     * @type {SCALE_MODE}
     * @default 'linear'
     * @example
     * ```ts
     * const container = new Container();
     * container.cacheAsTexture({ scaleMode: 'nearest' });
     * ```
     * @see {@link SCALE_MODE}
     */
    scaleMode?: SCALE_MODE;
}
/**
 * A RenderGroup is a class that is responsible for I generating a set of instructions that are used to render the
 * root container and its children. It also watches for any changes in that container or its children,
 * these changes are analysed and either the instruction set is rebuild or the instructions data is updated.
 * @category rendering
 * @advanced
 */
export declare class RenderGroup implements Instruction {
    renderPipeId: string;
    root: Container;
    canBundle: boolean;
    renderGroupParent: RenderGroup;
    renderGroupChildren: RenderGroup[];
    worldTransform: Matrix;
    worldColorAlpha: number;
    worldColor: number;
    worldAlpha: number;
    readonly childrenToUpdate: Record<number, {
        list: Container[];
        index: number;
    }>;
    updateTick: number;
    gcTick: number;
    readonly childrenRenderablesToUpdate: {
        list: Container[];
        index: number;
    };
    structureDidChange: boolean;
    instructionSet: InstructionSet;
    private readonly _onRenderContainers;
    /**
     * Indicates if the cached texture needs to be updated.
     * @default true
     */
    textureNeedsUpdate: boolean;
    /**
     * Indicates if the container should be cached as a texture.
     * @default false
     */
    isCachedAsTexture: boolean;
    /**
     * The texture used for caching the container. this is only set if isCachedAsTexture is true.
     * It can only be accessed after a render pass.
     * @type {Texture | undefined}
     */
    texture?: Texture;
    /**
     * The bounds of the cached texture.
     * @type {Bounds | undefined}
     * @ignore
     */
    _textureBounds?: Bounds;
    /**
     * The options for caching the container as a texture.
     * @type {CacheAsTextureOptions}
     */
    textureOptions: CacheAsTextureOptions;
    /**
     *  holds a reference to the batchable render sprite
     *  @ignore
     */
    _batchableRenderGroup: BatchableSprite;
    /**
     * Holds a reference to the closest parent RenderGroup that has isCachedAsTexture enabled.
     * This is used to properly transform coordinates when rendering into cached textures.
     * @type {RenderGroup | null}
     * @ignore
     */
    _parentCacheAsTextureRenderGroup: RenderGroup;
    private _inverseWorldTransform;
    private _textureOffsetInverseTransform;
    private _inverseParentTextureTransform;
    private _matrixDirty;
    init(root: Container): void;
    enableCacheAsTexture(options?: CacheAsTextureOptions): void;
    disableCacheAsTexture(): void;
    updateCacheTexture(): void;
    reset(): void;
    get localTransform(): Matrix;
    addRenderGroupChild(renderGroupChild: RenderGroup): void;
    private _removeRenderGroupChild;
    addChild(child: Container): void;
    removeChild(child: Container): void;
    removeChildren(children: Container[]): void;
    onChildUpdate(child: Container): void;
    updateRenderable(renderable: ViewContainer): void;
    onChildViewUpdate(child: Container): void;
    get isRenderable(): boolean;
    /**
     * adding a container to the onRender list will make sure the user function
     * passed in to the user defined 'onRender` callBack
     * @param container - the container to add to the onRender list
     */
    addOnRender(container: Container): void;
    removeOnRender(container: Container): void;
    runOnRender(renderer: Renderer): void;
    destroy(): void;
    getChildren(out?: Container[]): Container[];
    private _getChildren;
    invalidateMatrices(): void;
    /**
     * Returns the inverse of the world transform matrix.
     * @returns {Matrix} The inverse of the world transform matrix.
     */
    get inverseWorldTransform(): Matrix;
    /**
     * Returns the inverse of the texture offset transform matrix.
     * @returns {Matrix} The inverse of the texture offset transform matrix.
     */
    get textureOffsetInverseTransform(): Matrix;
    /**
     * Returns the inverse of the parent texture transform matrix.
     * This is used to properly transform coordinates when rendering into cached textures.
     * @returns {Matrix} The inverse of the parent texture transform matrix.
     */
    get inverseParentTextureTransform(): Matrix;
    /**
     * Returns a matrix that transforms coordinates to the correct coordinate space of the texture being rendered to.
     * This is the texture offset inverse transform of the closest parent RenderGroup that is cached as a texture.
     * @returns {Matrix | null} The transform matrix for the cached texture coordinate space,
     * or null if no parent is cached as texture.
     */
    get cacheToLocalTransform(): Matrix;
}
