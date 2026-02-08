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
from _pyinstaller_hooks_contrib.utils.mypy import find_mypyc_module_for_dist

# pytokens >= 0.4.0 uses `mypy`, and includes a top-level module with dynamically-generated name prefix;
# for example, `fd7dcdb10166ebd4db98__mypyc`.
hiddenimports = find_mypyc_module_for_dist('pytokens')
