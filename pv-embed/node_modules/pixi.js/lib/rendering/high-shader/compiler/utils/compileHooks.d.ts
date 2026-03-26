/**
 * takes a program string and returns an hash mapping the hooks to empty arrays
 * @param programSrc - the program containing hooks
 * @internal
 */
export declare function compileHooks(programSrc: string): Record<string, string[]>;
