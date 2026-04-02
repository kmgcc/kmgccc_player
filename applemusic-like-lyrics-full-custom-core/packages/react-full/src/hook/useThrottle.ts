import { useEffect, useRef, useCallback } from "react";

/**
 * 创建一个函数的节流版本，在指定的延迟时间内最多只执行一次。
 * 这是一个 React hook，能够安全地处理组件重渲染和回调函数的变化。
 *
 * @template T - 回调函数的类型。
 * @param {T} callback - 需要进行节流处理的函数。
 * @param {number} delay - 节流的延迟时间（毫秒）。
 * @returns {T} - 返回一个节流后的新函数。
 */
export function useThrottle<T extends (...args: any[]) => any>(
	callback: T,
	delay: number,
): T {
	// 使用 ref 存储最新的回调函数，避免因回调函数变化而重新创建节流逻辑
	const callbackRef = useRef(callback);

	// 使用 ref 存储计时器 ID
	const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

	// 使用 ref 标记是否处于节流的“冷却”期间
	const inThrottleRef = useRef(false);

	// 当传入的 callback 函数更新时，同步更新 ref 中的值
	// 这确保了节流函数在任何时候调用的都是最新的回调逻辑
	useEffect(() => {
		callbackRef.current = callback;
	}, [callback]);

	// 当组件卸载时，清除可能存在的计时器，防止内存泄漏
	useEffect(() => {
		return () => {
			if (timeoutRef.current) {
				clearTimeout(timeoutRef.current);
			}
		};
	}, []);

	// 使用 useCallback 创建节流函数，并将其作为 hook 的返回值
	// 依赖项是 `delay`，因此只有当延迟时间变化时，这个函数本身才会重新创建
	const throttledCallback = useCallback(
		(...args: Parameters<T>) => {
			// 如果正处于冷却期间，则不执行任何操作
			if (inThrottleRef.current) {
				return;
			}

			// 执行回调函数
			callbackRef.current(...args);

			// 进入冷却期
			inThrottleRef.current = true;

			// 设置一个计时器，在 delay 毫秒后结束冷却期
			timeoutRef.current = setTimeout(() => {
				inThrottleRef.current = false;
			}, delay);
		},
		[delay],
	);

	return throttledCallback as T;
}
