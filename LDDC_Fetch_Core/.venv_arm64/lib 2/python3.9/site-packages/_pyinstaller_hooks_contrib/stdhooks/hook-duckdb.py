# ------------------------------------------------------------------
# Copyright (c) 2025 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

from PyInstaller.utils.hooks import copy_metadata, is_module_satisfies

# duckdb requires stdlib `inspect` module. On newer python versions (>= 3.10), it is collected as a dependency of other
# stdlib modules, while on older python versions this is not the case. Therefore, we add it to hidden imports regardless
# of python version.
hiddenimports = ['inspect']

# Starting with v1.4.0, `duckdb` uses `importlib.metadata.version()` to determine its version.
if is_module_satisfies("duckdb >= 1.4.0"):
    datas = copy_metadata('duckdb')
