# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Hashable


@dataclass
class _Entry:
    value: Any
    expire_at: float | None


class TTLCache:
    def __init__(self) -> None:
        self._data: dict[Hashable, _Entry] = {}

    def get(self, key: Hashable, default: Any = None) -> Any:
        ent = self._data.get(key)
        if ent is None:
            return default
        if ent.expire_at is not None and ent.expire_at <= time.time():
            self._data.pop(key, None)
            return default
        return ent.value

    def set(self, key: Hashable, value: Any, expire_seconds: int | None = None) -> None:
        expire_at = (time.time() + expire_seconds) if expire_seconds else None
        self._data[key] = _Entry(value=value, expire_at=expire_at)


cache = TTLCache()

