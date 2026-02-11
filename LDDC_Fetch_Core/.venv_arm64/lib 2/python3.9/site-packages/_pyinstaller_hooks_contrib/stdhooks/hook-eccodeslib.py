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

from PyInstaller.utils.hooks import collect_dynamic_libs

# Collect bundled dynamic libraries.
binaries = collect_dynamic_libs('eccodeslib')

# `eccodeslib` depends on `eckitlib` and `fckitlib`, and when libraries are being imported at run-time by
# `findlibs.find()` user warnings are emitted if these packages cannot be imported.
hiddenimports = ['eckitlib', 'fckitlib']
