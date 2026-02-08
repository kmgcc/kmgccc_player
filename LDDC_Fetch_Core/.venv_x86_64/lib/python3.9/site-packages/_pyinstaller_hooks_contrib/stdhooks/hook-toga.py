# ------------------------------------------------------------------
# Copyright (c) 2024 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

from PyInstaller import compat
from PyInstaller.utils.hooks import collect_data_files, collect_submodules, copy_metadata, is_module_satisfies

hiddenimports = []

# Select the platform-specific backend.
if compat.is_darwin:
    backend = 'cocoa'
elif compat.is_linux:
    backend = 'gtk'
elif compat.is_win:
    backend = 'winforms'
else:
    backend = None

if backend is not None:
    hiddenimports += [f'toga_{backend}', f'toga_{backend}.factory']

# Collect metadata for toga-core dist, which is used by toga module to determine its version.
datas = copy_metadata("toga-core")

# Prevent `toga` from pulling `setuptools_scm` into frozen application, as it makes no sense in that context.
excludedimports = ["setuptools_scm"]

# `toga` 0.5.0 refactored its `__init__.py` to lazy-load its core modules. Therefore, we now need to collect
# submodules via `collect_submodules`...
if is_module_satisfies("toga >= 0.5.0"):
    hiddenimports += collect_submodules("toga")

# Starting with `toga` 0.5.2, we need to collect .pyi files.
if is_module_satisfies("toga >= 0.5.2"):
    datas += collect_data_files("toga")
