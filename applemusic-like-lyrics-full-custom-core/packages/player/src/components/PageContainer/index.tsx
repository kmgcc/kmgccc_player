import type { FC, PropsWithChildren } from "react";
import styles from "./index.module.css";

export const PageContainer: FC<PropsWithChildren> = ({ children }) => {
	return <div className={styles.container}>{children}</div>;
};
