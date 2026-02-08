# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from zlib import decompress

from lddc_fetch_core.exceptions import LyricsDecryptError

from .qmc1 import qmc1_decrypt
from .tripledes import DECRYPT, tripledes_crypt, tripledes_key_setup

QRC_KEY = b"!@#)(*$%123ZXC!@!@#)(NHL"
KRC_KEY = b"@Gaw^2tGQ61-\xce\xd2ni"


def qrc_decrypt(encrypted_qrc: str | bytearray | bytes, local_qrc: bool = False) -> str:
    if encrypted_qrc is None or (isinstance(encrypted_qrc, str) and encrypted_qrc.strip() == ""):
        raise LyricsDecryptError("没有可解密的数据")

    if isinstance(encrypted_qrc, str):
        encrypted_text_byte = bytearray.fromhex(encrypted_qrc)
    elif isinstance(encrypted_qrc, bytearray):
        encrypted_text_byte = encrypted_qrc
    elif isinstance(encrypted_qrc, bytes):
        encrypted_text_byte = bytearray(encrypted_qrc)
    else:
        raise LyricsDecryptError("无效的加密数据类型")

    try:
        if local_qrc:
            qmc1_decrypt(encrypted_text_byte)
            encrypted_text_byte = encrypted_text_byte[11:]

        data = bytearray()
        schedule = tripledes_key_setup(QRC_KEY, DECRYPT)

        for i in range(0, len(encrypted_text_byte), 8):
            data += tripledes_crypt(encrypted_text_byte[i:], schedule)

        return decompress(data).decode("utf-8")
    except Exception as e:  # noqa: BLE001
        raise LyricsDecryptError("QRC解密失败") from e


def krc_decrypt(encrypted_lyrics: bytearray | bytes) -> str:
    if isinstance(encrypted_lyrics, bytes):
        encrypted_data = bytearray(encrypted_lyrics)[4:]
    elif isinstance(encrypted_lyrics, bytearray):
        encrypted_data = encrypted_lyrics[4:]
    else:
        raise LyricsDecryptError("无效的加密数据类型")

    try:
        decrypted_data = bytearray()
        for i, item in enumerate(encrypted_data):
            decrypted_data.append(item ^ KRC_KEY[i % len(KRC_KEY)])
        return decompress(decrypted_data).decode("utf-8")
    except Exception as e:  # noqa: BLE001
        raise LyricsDecryptError("KRC解密失败") from e

