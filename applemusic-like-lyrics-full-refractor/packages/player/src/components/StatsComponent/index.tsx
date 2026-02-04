import { useEffect, useRef } from "react";
import * as Stats from "stats.js";

export const StatsComponent = () => {
	const containerRef = useRef<HTMLDivElement | null>(null);

	useEffect(() => {
		const StatsConstructor = (Stats as any).default || Stats;
		if (typeof StatsConstructor !== "function") {
			console.error("Failed to load stats.js constructor.");
			return;
		}

		const statsInstance = new StatsConstructor();

		const domNode = statsInstance.dom || statsInstance.domElement;

		if (!(domNode instanceof Node)) {
			console.error(
				"stats.dom or stats.domElement is not a valid Node. statsInstance:",
				statsInstance,
			);
			return;
		}

		const container = containerRef.current;
		if (!container) return;

		container.appendChild(domNode);

		(domNode as HTMLElement).style.position = "absolute";
		(domNode as HTMLElement).style.left = "0";
		(domNode as HTMLElement).style.top = "0";

		let animationFrameId: number;
		const update = () => {
			statsInstance.begin();
			statsInstance.end();
			animationFrameId = requestAnimationFrame(update);
		};
		animationFrameId = requestAnimationFrame(update);

		return () => {
			cancelAnimationFrame(animationFrameId);
			if (container.contains(domNode)) {
				container.removeChild(domNode);
			}
		};
	}, []);

	return (
		<div
			ref={containerRef}
			style={{
				position: "fixed",
				left: "1em",
				top: "3em",
				zIndex: 9999,
				width: "80px",
				height: "48px",
			}}
		/>
	);
};
