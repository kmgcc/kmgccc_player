/**
 * takes a shader src and replaces any hooks with the HighFragment code.
 * @param templateSrc - the program src template
 * @param fragmentParts - the fragments to inject
 * @internal
 */
export declare function injectBits(templateSrc: string, fragmentParts: Record<string, string[]>): string;
