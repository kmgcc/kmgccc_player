/**
 * takes the HighFragment source parts and adds them to the hook hash
 * @param srcParts - the hash of hook arrays
 * @param parts - the code to inject into the hooks
 * @param name - optional the name of the part to add
 * @internal
 */
export declare function addBits(srcParts: Record<string, string>, parts: Record<string, string[]>, name?: string): void;
