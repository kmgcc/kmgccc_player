import classNames from "classnames";
import React, {
	type HTMLProps,
	type JSX,
	useEffect,
	useLayoutEffect,
	useRef,
	useState,
} from "react";
import { Spring } from "../../utils/spring";
import styles from "./index.module.css";

export interface SliderProps
	extends Omit<HTMLProps<HTMLDivElement>, "onChange" | "onSeeking"> {
	onAfterChange?: (v: number) => void;
	onBeforeChange?: () => void;
	onChange?: (v: number) => void;
	onSeeking?: (v: boolean) => void;
	value: number;
	min: number;
	max: number;
	beforeIcon?: JSX.Element;
	afterIcon?: JSX.Element;
	disabled?: boolean;
}

export const BouncingSlider: React.FC<SliderProps> = (props) => {
	const {
		className,
		style,
		value,
		onAfterChange,
		onBeforeChange,
		onChange,
		onSeeking,
		min,
		max,
		beforeIcon,
		afterIcon,
		disabled = false,
		...others
	} = props;

	const [curValue, setCurValue] = useState(value);

	const outerRef = useRef<HTMLDivElement>(null);
	const innerRef = useRef<HTMLDivElement>(null);

	const isSeekingRef = useRef(false);
	const draggingRef = useRef(false);
	const hasMovedRef = useRef(false);

	const latestProps = useRef(props);
	useLayoutEffect(() => {
		latestProps.current = props;
	});

	useEffect(() => {
		if (!isSeekingRef.current) {
			setCurValue(value);
		}
	}, [value]);

	useEffect(() => {
		const outer = outerRef.current;
		const inner = innerRef.current;

		if (outer && inner) {
			const heightSpring = new Spring(80);
			const bounceSpring = new Spring(0);
			heightSpring.updateParams({ stiffness: 150, mass: 1, damping: 10 });
			bounceSpring.updateParams({ stiffness: 150 });

			let lastTime: number | null = null;
			let handler = 0;

			const onFrame = (dt: number) => {
				lastTime ??= dt;
				const delta = (dt - lastTime) / 1000;

				bounceSpring.update(delta);
				heightSpring.update(delta);
				outer.style.transform = `translateX(${
					bounceSpring.getCurrentPosition() / 100
				}px)`;
				if (innerHeight <= 1000)
					inner.style.height = `${heightSpring.getCurrentPosition() * 0.08}px`;
				else inner.style.height = `${heightSpring.getCurrentPosition() / 10}px`;

				lastTime = dt;

				if (heightSpring.arrived() && bounceSpring.arrived()) {
					if (handler) {
						cancelAnimationFrame(handler);
						handler = 0;
					}
				} else {
					handler = requestAnimationFrame(onFrame);
				}
			};

			const startAnimation = () => {
				if (!handler) {
					lastTime = null;
					handler = requestAnimationFrame(onFrame);
				}
			};

			const setValue = (evt: MouseEvent) => {
				const { onChange, onSeeking, min, max } = latestProps.current;
				const rect = inner.getBoundingClientRect();
				const relPos = (evt.clientX - rect.left) / rect.width;

				if (relPos > 1) {
					const o = (relPos - 1) * 900;
					bounceSpring.setPosition(o);
					bounceSpring.setTargetPosition(o);
				} else if (relPos < 0) {
					const o = relPos * 900;
					bounceSpring.setPosition(o);
					bounceSpring.setTargetPosition(o);
				} else {
					bounceSpring.setPosition(0);
					bounceSpring.setTargetPosition(0);
				}

				const v = Math.min(max, Math.max(min, min + (max - min) * relPos));
				onChange?.(v);
				onSeeking?.(true);
				setCurValue(v);
				startAnimation();
			};

			const onMouseEnter = (evt: MouseEvent) => {
				heightSpring.setTargetPosition(189);
				evt.stopImmediatePropagation();
				evt.stopPropagation();
				evt.preventDefault();
				startAnimation();
			};

			const onMouseLeave = (evt: MouseEvent) => {
				if (!draggingRef.current) {
					heightSpring.setTargetPosition(80);
					evt.stopImmediatePropagation();
					evt.stopPropagation();
					evt.preventDefault();
					startAnimation();
					const { onSeeking } = latestProps.current;
					onSeeking?.(false);
				}
			};

			const onMouseDown = (evt: MouseEvent) => {
				evt.stopImmediatePropagation();
				evt.stopPropagation();
				evt.preventDefault();
				heightSpring.setTargetPosition(189);
				draggingRef.current = true;
				hasMovedRef.current = false;
				isSeekingRef.current = true;
				window.addEventListener("mousemove", onMouseMove);
				window.addEventListener("mouseup", onMouseUp);
				const { onBeforeChange } = latestProps.current;
				onBeforeChange?.();
				startAnimation();
			};

			const onMouseUp = (evt: MouseEvent) => {
				evt.stopImmediatePropagation();
				evt.stopPropagation();
				evt.preventDefault();

				if (!hasMovedRef.current) {
					setValue(evt);
				}

				if (!outer.contains(evt.target as Node)) {
					heightSpring.setTargetPosition(80);
				}

				draggingRef.current = false;
				isSeekingRef.current = false;
				window.removeEventListener("mousemove", onMouseMove);
				window.removeEventListener("mouseup", onMouseUp);
				bounceSpring.setTargetPosition(0);

				const { onSeeking, onAfterChange } = latestProps.current;
				onSeeking?.(false);
				onAfterChange?.(curValue);
				startAnimation();
			};

			const onMouseMove = (evt: MouseEvent) => {
				hasMovedRef.current = true;
				setValue(evt);
			};

			inner.addEventListener("mousedown", onMouseDown);
			outer.addEventListener("mouseenter", onMouseEnter);
			outer.addEventListener("mouseleave", onMouseLeave);

			return () => {
				if (handler) {
					cancelAnimationFrame(handler);
				}
				inner.removeEventListener("mousedown", onMouseDown);
				outer.removeEventListener("mouseenter", onMouseEnter);
				outer.removeEventListener("mouseleave", onMouseLeave);
				window.removeEventListener("mouseup", onMouseUp);
				window.removeEventListener("mousemove", onMouseMove);
			};
		}
	}, []);

	return (
		<div
			ref={outerRef}
			className={classNames(styles.nowPlayingSlider, className)}
			style={style}
			{...others}
		>
			{beforeIcon}
			<div ref={innerRef} className={styles.inner}>
				<div
					className={styles.thumb}
					style={{
						width: `${((curValue - min) / (max - min)) * 100}%`,
					}}
				/>
			</div>
			{afterIcon}
		</div>
	);
};
