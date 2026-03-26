import { GraphicsPath } from '../path/GraphicsPath';
import type { FillGradient } from '../fill/FillGradient';
import type { GraphicsContext } from '../GraphicsContext';
/**
 * Represents a session for SVG parsing. Contains the current state and resources needed during parsing.
 * @internal
 */
export interface Session {
    /** The graphics context to render to */
    context: GraphicsContext;
    /** The current path being constructed */
    path: GraphicsPath;
    /** Map of definitions by id */
    defs: Record<string, FillGradient>;
}
/**
 * Parses an SVG element or string and renders it to a graphics context.
 * Handles both SVG strings and SVG DOM elements as input.
 * @param svg - The SVG content to parse, either as a string or element
 * @param graphicsContext - Optional graphics context to render to
 * @returns The graphics context with the SVG rendered into it
 * @internal
 */
export declare function SVGParser(svg: string | SVGElement | SVGSVGElement, graphicsContext?: GraphicsContext): GraphicsContext;
