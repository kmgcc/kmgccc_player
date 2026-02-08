# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import argparse
import sys

from lddc_fetch_core.fetch import fetch_lrc
from lddc_fetch_core.models import Source


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="lddc-fetch", description="Fetch LRC by title+artist.")
    p.add_argument("--title", required=True)
    p.add_argument("--artist", default=None)
    p.add_argument("--mode", choices=["line", "verbatim", "enhanced"], default="verbatim")
    p.add_argument("--translation", choices=["none", "provider", "openai", "auto"], default="none")
    p.add_argument("--offset-ms", type=int, default=0)
    p.add_argument("--ms-digits", type=int, choices=[2, 3], default=3)
    p.add_argument("--sources", default="LRCLIB,QM,KG,NE", help="Comma-separated: LRCLIB,QM,KG,NE")

    p.add_argument("--openai-base-url", default="")
    p.add_argument("--openai-api-key", default="")
    p.add_argument("--openai-model", default="")
    p.add_argument("--openai-target-lang", default="简体中文")

    args = p.parse_args(argv)

    srcs = tuple(Source[s.strip()] for s in args.sources.split(",") if s.strip())

    try:
        out = fetch_lrc(
            title=args.title,
            artist=args.artist,
            mode=args.mode,
            translation=args.translation,
            offset_ms=args.offset_ms,
            ms_digits=args.ms_digits,
            sources=srcs,
            openai_base_url=args.openai_base_url,
            openai_api_key=args.openai_api_key,
            openai_model=args.openai_model,
            openai_target_lang=args.openai_target_lang,
        )
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: {e.__class__.__name__}: {e}", file=sys.stderr)
        return 2

    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

