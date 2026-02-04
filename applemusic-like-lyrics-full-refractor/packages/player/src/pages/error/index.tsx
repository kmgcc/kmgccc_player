import { Box, Button, Card, Code, Flex, Text } from "@radix-ui/themes";
import { type FC, useMemo } from "react";
import { Trans } from "react-i18next";
import { Link, useRouteError } from "react-router-dom";
import { AppContainer } from "../../components/AppContainer/index.tsx";

export const Component: FC = () => {
	const error = useRouteError();
	console.error("An error was occured when running:", error);
	const errorText = useMemo(() => {
		if (error instanceof Error) return error.stack ?? error.message;

		if (error instanceof Object)
			if ("error" in error) {
				if (error.error instanceof Error) {
					return error.error.stack ?? error.error.message;
				}
				return String(error.error);
			}

		try {
			return JSON.stringify(error);
		} catch {}
		return String(error);
	}, [error]);
	return (
		<AppContainer>
			<Flex p="4" py="6" direction="column" gap="2" height="100%">
				<Text size="6" weight="bold">
					<Trans i18nKey="error.title">程序发生错误</Trans>
				</Text>
				<Text>
					<Trans i18nKey="error.desc0">
						程序在运行时发生了错误，请尝试刷新页面，如果问题仍然无法解决，请联系开发者。
					</Trans>
				</Text>
				<Text>
					<Trans i18nKey="error.desc1">
						如果您对程序调试有一定了解，可以在开发者控制台中看到更加准确的错误信息。
					</Trans>
				</Text>
				<Flex gap="2" flexShrink="0">
					<Button onClick={() => location.reload()}>
						<Trans i18nKey="error.reloadPage">刷新页面</Trans>
					</Button>
					<Button asChild>
						<Link to="/" replace>
							<Trans i18nKey="error.backToMainPage">回到主页</Trans>
						</Link>
					</Button>
					<Button
						onClick={() => {
							navigator.clipboard.writeText(errorText);
						}}
					>
						<Trans i18nKey="error.copyError">复制错误信息</Trans>
					</Button>
				</Flex>
				<Text>
					<Trans i18nKey="error.errorDetail">错误信息</Trans>
				</Text>
				<Card
					style={{
						flexGrow: "1",
						padding: "0",
					}}
				>
					<Box overflow="auto" height="100%">
						<Code
							variant="ghost"
							style={{
								userSelect: "all",
								cursor: "text",
								whiteSpace: "pre",
								padding: "1em",
							}}
						>
							{errorText}
						</Code>
					</Box>
				</Card>
			</Flex>
		</AppContainer>
	);
};

Component.displayName = "ErrorPage";

export default Component;
