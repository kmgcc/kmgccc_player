# ------------------------------------------------------------------
# Copyright (c) 2026 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

from PyInstaller.utils.hooks import collect_submodules

# The .ddgs module is lazily loaded, and is discovered only because PyInstaller currently analyzes imports under
# `if TYPE_CHECKING`. See: https://github.com/deedy5/ddgs/blob/v9.10.0/ddgs/__init__.py#L14-L15
hiddenimports = ['ddgs.ddgs']

# The engines/backends are discovered via `pkgutil.iter_modules()`, so we need to ensure they are collected.
hiddenimports += collect_submodules('ddgs.engines')
