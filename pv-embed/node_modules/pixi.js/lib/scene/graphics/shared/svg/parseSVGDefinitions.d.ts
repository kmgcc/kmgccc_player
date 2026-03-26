import type { Session } from './SVGParser';
/**
 * Parses SVG gradient definitions and stores them in the session for later use.
 * Currently supports linear gradients and has placeholder support for radial gradients.
 * @param svg - The root SVG element to parse definitions from
 * @param session - The parsing session to store definitions in
 * @internal
 */
export declare function parseSVGDefinitions(svg: SVGElement, session: Session): void;
