import { musicQualityAtom } from "@applemusic-like-lyrics/react-full";
import { Button, DataList, Dialog, Separator } from "@radix-ui/themes";
import { useAtom, useAtomValue } from "jotai";
import type { FC } from "react";
import { Trans } from "react-i18next";
import { audioQualityDialogOpenedAtom } from "../../states/smtcAtoms";

export const AudioQualityDialog: FC = () => {
	const [audioQualityDialogOpened, setAudioQualityDialogOpened] = useAtom(
		audioQualityDialogOpenedAtom,
	);
	const musicQuality = useAtomValue(musicQualityAtom);

	return (
		<Dialog.Root
			open={audioQualityDialogOpened}
			onOpenChange={setAudioQualityDialogOpened}
		>
			<Dialog.Content width="fit-content">
				<Dialog.Title>
					<Trans i18nKey="amll.audioQuality.title">音频解码信息</Trans>
				</Dialog.Title>
				<Separator size="4" my="3" />
				<DataList.Root>
					<DataList.Item>
						<DataList.Label>
							<Trans i18nKey="amll.audioQuality.codec">音频解码器</Trans>
						</DataList.Label>
						<DataList.Value>{musicQuality.codec}</DataList.Value>
					</DataList.Item>
					<DataList.Item>
						<Trans i18nKey="amll.audioQuality.channels">音频通道数量</Trans>
						<DataList.Value>{musicQuality.channels}</DataList.Value>
					</DataList.Item>
					<DataList.Item>
						<Trans i18nKey="amll.audioQuality.sampleRate">采样率</Trans>
						<DataList.Value>{musicQuality.sampleRate} hz</DataList.Value>
					</DataList.Item>
					<DataList.Item>
						<Trans i18nKey="amll.audioQuality.sampleFormat">采样格式</Trans>
						<DataList.Value>{musicQuality.sampleFormat}</DataList.Value>
					</DataList.Item>
				</DataList.Root>
				<Separator size="4" my="3" />
				<Dialog.Close>
					<Button>
						<Trans i18nKey="common.dialog.close">关闭</Trans>
					</Button>
				</Dialog.Close>
			</Dialog.Content>
		</Dialog.Root>
	);
};
