import classNames from "classnames";
import {
	animate,
	motion,
	type PanInfo,
	useAnimationFrame,
	useMotionTemplate,
	useMotionValue,
	useSpring,
	useTransform,
} from "framer-motion";
import type React from "react";
import { useEffect, useRef } from "react";
import styles from "./index.module.css";

export interface SliderProps {
	className?: string;
	style?: React.CSSProperties;
	value: number;
	min: number;
	max: number;
	isPlaying?: boolean;
	onChange?: (v: number) => void;
	onAfterChange?: (v: number) => void;
	onBeforeChange?: () => void;
	onSeeking?: (v: boolean) => void;
	beforeIcon?: React.ReactNode;
	afterIcon?: React.ReactNode;
	changeOnDrag?: boolean;
}

const MAX_HEIGHT = 20;
const MIN_HEIGHT = 8;
const INITIAL_INSET = (MAX_HEIGHT - MIN_HEIGHT) / 2;

const MAX_BOUNCE_DISTANCE = 12;

export const BouncingSlider: React.FC<SliderProps> = ({
	className,
	style,
	value,
	min,
	max,
	isPlaying = false,
	onChange,
	onAfterChange,
	onBeforeChange,
	onSeeking,
	beforeIcon,
	afterIcon,
	changeOnDrag = false,
}) => {
	const containerRef = useRef<HTMLDivElement>(null);
	const innerRef = useRef<HTMLDivElement>(null);
	const rectRef = useRef<DOMRect | null>(null);
	const isHoveringRef = useRef(false);

	const progressMv = useMotionValue(0);
	const scaleX = useTransform(progressMv, [0, 1], [0, 1]);

	const insetMv = useMotionValue(INITIAL_INSET);

	const clipPath = useMotionTemplate`inset(${insetMv}px 0px round 100px)`;

	const bounceXSpring = useSpring(0, { damping: 12, stiffness: 300 });

	const isDraggingRef = useRef(false);
	const localTimeRef = useRef(value);

	useEffect(() => {
		if (isDraggingRef.current) return;

		localTimeRef.current = value;
		const newProgress = Math.max(0, Math.min(1, (value - min) / (max - min)));
		progressMv.set(newProgress);
	}, [value, min, max, progressMv]);

	useAnimationFrame((_time, delta) => {
		if (isPlaying && !isDraggingRef.current) {
			localTimeRef.current += delta;

			if (localTimeRef.current > max) localTimeRef.current = max;

			const newProgress = Math.max(
				0,
				Math.min(1, (localTimeRef.current - min) / (max - min)),
			);
			progressMv.set(newProgress);
		}
	});

	const expand = () => {
		animate(insetMv, 0, { type: "tween", ease: "easeOut", duration: 0.28 });
	};

	const collapse = () => {
		animate(insetMv, INITIAL_INSET, {
			type: "spring",
			damping: 12,
			stiffness: 200,
		});
	};

	const handlePanStart = (_event: MouseEvent | TouchEvent | PointerEvent) => {
		isDraggingRef.current = true;

		if (innerRef.current) {
			rectRef.current = innerRef.current.getBoundingClientRect();
		}

		expand();

		onBeforeChange?.();
		onSeeking?.(true);
	};

	const handlePan = (
		_event: MouseEvent | TouchEvent | PointerEvent,
		info: PanInfo,
	) => {
		const rect = rectRef.current;
		if (!rect) return;

		const relPos = (info.point.x - rect.left) / rect.width;

		if (relPos < 0) {
			bounceXSpring.set(Math.tanh(relPos * 2) * MAX_BOUNCE_DISTANCE);
		} else if (relPos > 1) {
			bounceXSpring.set(Math.tanh((relPos - 1) * 2) * MAX_BOUNCE_DISTANCE);
		} else {
			bounceXSpring.set(0);
		}

		const clampedPos = Math.max(0, Math.min(1, relPos));
		const NewValue = min + clampedPos * (max - min);

		localTimeRef.current = NewValue;

		progressMv.set(clampedPos);

		if (changeOnDrag) {
			onChange?.(NewValue);
		}
	};

	const handlePanEnd = () => {
		isDraggingRef.current = false;
		rectRef.current = null;

		if (isHoveringRef.current) {
			expand();
		} else {
			collapse();
		}

		bounceXSpring.set(0);

		onSeeking?.(false);

		onChange?.(localTimeRef.current);

		onAfterChange?.(localTimeRef.current);
	};

	const handleHoverStart = () => {
		isHoveringRef.current = true;
		if (!isDraggingRef.current) {
			expand();
		}
	};

	const handleHoverEnd = () => {
		isHoveringRef.current = false;
		if (!isDraggingRef.current) {
			collapse();
		}
	};

	const handleTap = (
		_event: MouseEvent | TouchEvent | PointerEvent,
		info: PanInfo,
	) => {
		const rect = innerRef.current?.getBoundingClientRect();
		if (!rect) return;

		const relPos = Math.max(
			0,
			Math.min(1, (info.point.x - rect.left) / rect.width),
		);

		const NewValue = min + relPos * (max - min);

		localTimeRef.current = NewValue;
		progressMv.set(relPos);

		onBeforeChange?.();
		onChange?.(NewValue);
		onAfterChange?.(NewValue);
	};

	return (
		<motion.div
			ref={containerRef}
			className={classNames(styles.nowPlayingSlider, className)}
			style={{
				...style,
				x: bounceXSpring,
			}}
			onPanStart={handlePanStart}
			onPan={handlePan}
			onPanEnd={handlePanEnd}
			onTap={handleTap}
			onHoverStart={handleHoverStart}
			onHoverEnd={handleHoverEnd}
		>
			{beforeIcon}
			<motion.div
				ref={innerRef}
				className={styles.inner}
				style={{
					clipPath: clipPath,
				}}
			>
				<motion.div
					className={styles.thumb}
					style={{
						scaleX: scaleX,
						originX: 0,
					}}
				/>
			</motion.div>

			{afterIcon}
		</motion.div>
	);
};
