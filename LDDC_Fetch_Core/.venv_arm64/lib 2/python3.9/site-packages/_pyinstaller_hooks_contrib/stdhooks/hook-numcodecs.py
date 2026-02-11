# ------------------------------------------------------------------
# Copyright (c) 2022 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

from PyInstaller.utils.hooks import is_module_satisfies

# compat_ext is only imported from pyx files, so it is missed
hiddenimports = ['numcodecs.compat_ext']

# numcodecs v0.15.0 added an import of `deprecated` (from `Deprecated` dist) in one of its cythonized extension.
if is_module_satisfies('numcodecs >= 0.15.0'):
    hiddenimports += ['deprecated']
