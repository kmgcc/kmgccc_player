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

import sys
from PyInstaller.utils.hooks import can_import_module, copy_metadata, is_module_satisfies

# Starting with narwhals 1.35.0, we need to collect metadata for `typing_extensions` if the module is available.
# The codepath that checks metadata for `typing_extensions` is not executed under python >= 3.13, so we can avoid
# collection there.
datas = []
if sys.version_info < (3, 13):  # PyInstaller.compat.is_py313 is available only in PyInstaller >= 6.10.0.
    if is_module_satisfies("narwhals >= 1.35.0") and can_import_module("typing_extensions"):
        datas += copy_metadata("typing_extensions")
