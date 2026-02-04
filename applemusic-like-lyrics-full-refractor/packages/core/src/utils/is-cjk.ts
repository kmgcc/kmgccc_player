export const isCJK = (char: string) => {
	return /^[\p{Unified_Ideograph}\u0800-\u9FFC]+$/u.test(char);
};
