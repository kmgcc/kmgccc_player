/**
 * Represents a render target.
 * @category rendering
 * @ignore
 */
export declare class GlRenderTarget {
    width: number;
    height: number;
    msaa: boolean;
    /**
     * Tracks which mip level is currently attached to this render target's framebuffer.
     * This lets us skip redundant framebufferTexture2D calls on the common path.
     * @internal
     */
    _attachedMipLevel: number;
    /**
     * Tracks which array layer (or cube face index) is currently attached to this render target's framebuffer.
     * For non-array 2D textures this will always be 0.
     * @internal
     */
    _attachedLayer: number;
    framebuffer: WebGLFramebuffer;
    resolveTargetFramebuffer: WebGLFramebuffer;
    msaaRenderBuffer: WebGLRenderbuffer[];
    depthStencilRenderBuffer: WebGLRenderbuffer;
}
