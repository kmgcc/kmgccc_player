# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations


class LDDCFetchError(Exception):
    pass


class APIRequestError(LDDCFetchError):
    pass


class APIParamsError(LDDCFetchError):
    pass


class LyricsNotFoundError(LDDCFetchError):
    pass


class LyricsDecryptError(LDDCFetchError):
    pass


class LyricsProcessingError(LDDCFetchError):
    pass


class TranslateError(LDDCFetchError):
    pass

