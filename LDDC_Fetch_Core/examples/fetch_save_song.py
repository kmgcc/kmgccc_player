# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from pathlib import Path

from lddc_fetch_core import fetch_lrc


def main() -> None:
    title = "守望者"
    artist = "司南"

    lrc = fetch_lrc(
        title=title,
        artist=artist,
        mode="verbatim",
        translation="provider",
        offset_ms=0,
    )

    out_dir = Path(__file__).resolve().parent / "out"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{artist} - {title}.lrc"
    out_path.write_text(lrc, encoding="utf-8")
    print(out_path)


if __name__ == "__main__":
    main()

