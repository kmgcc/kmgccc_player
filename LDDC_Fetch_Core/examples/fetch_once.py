# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from lddc_fetch_core import fetch_lrc
from lddc_fetch_core.models import Source


def main() -> None:
    lrc = fetch_lrc(
        title="夜に駆ける",
        artist="YOASOBI",
        sources=(Source.LRCLIB, Source.QM, Source.KG, Source.NE),
        mode="verbatim",
        translation="provider",
        offset_ms=0,
    )
    print(lrc)


if __name__ == "__main__":
    main()

