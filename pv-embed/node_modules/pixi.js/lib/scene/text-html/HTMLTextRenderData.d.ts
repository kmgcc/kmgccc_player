import { type ImageLike } from '../../environment/ImageLike';
import type { CanvasAndContext } from '../../rendering/renderers/shared/texture/CanvasPool';
/** @internal */
export declare class HTMLTextRenderData {
    svgRoot: SVGSVGElement;
    foreignObject: SVGForeignObjectElement;
    domElement: HTMLElement;
    styleElement: HTMLElement;
    image: ImageLike;
    canvasAndContext?: CanvasAndContext;
    constructor();
    destroy(): void;
}
