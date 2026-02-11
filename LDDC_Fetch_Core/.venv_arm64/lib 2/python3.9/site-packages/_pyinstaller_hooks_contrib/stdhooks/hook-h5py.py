# ------------------------------------------------------------------
# Copyright (c) 2020 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------
"""
Hook for http://pypi.python.org/pypi/h5py/
"""

from PyInstaller.utils.hooks import collect_submodules

hiddenimports = collect_submodules("h5py", lambda x: "tests" not in x)
