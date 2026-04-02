import classNames from "classnames";
import { useAtom } from "jotai";
import { atomWithStorage } from "jotai/utils";
import {
	type FC,
	type PropsWithChildren,
	type ReactNode,
	useState,
} from "react";
import styles from "./index.module.css";

const sidebarWidthAtom = atomWithStorage("sidebarWidth", 256);

export const AppContainer: FC<
	PropsWithChildren<{
		sidebar?: ReactNode;
		playbar?: ReactNode;
	}>
> = ({ sidebar, playbar, children }) => {
	const [sidebarWidth, setSidebarWidth] = useAtom(sidebarWidthAtom);
	const [dragging, setDragging] = useState(false);
	const onSidebarDraggerMouseDown = () => {
		setDragging(true);
		const onMouseMove = (evt: MouseEvent) => {
			setSidebarWidth(
				Math.max(192, Math.min(512, window.innerWidth / 2, evt.clientX)),
			);
		};
		const onMouseUp = () => {
			window.removeEventListener("mousemove", onMouseMove);
			window.removeEventListener("mouseup", onMouseUp);
			setDragging(false);
		};
		window.addEventListener("mousemove", onMouseMove);
		window.addEventListener("mouseup", onMouseUp);
	};

	return (
		<div className={styles.appContainer}>
			<div className={styles.sidebar} style={{ width: `${sidebarWidth}px` }}>
				{sidebar}
			</div>
			<div
				className={classNames(
					styles.sidebarDivider,
					dragging && styles.dragging,
				)}
				style={{
					cursor:
						sidebarWidth === 192
							? "e-resize"
							: sidebarWidth === 512
								? "w-resize"
								: "ew-resize",
				}}
				onMouseDown={onSidebarDraggerMouseDown}
			/>
			<div className={styles.main}>{children}</div>
			<div className={styles.playbar}>{playbar}</div>
		</div>
	);
};
