# ------------------------------------------------------------------
# Copyright (c) 2021 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

from PyInstaller import isolated
from PyInstaller.utils.hooks import collect_submodules

hiddenimports = collect_submodules("ffpyplayer")
binaries = []


# ffpyplayer has an internal variable that list locations of libraries it is using.
@isolated.decorate
def _get_ffpyplayer_binary_dirs():
    import ffpyplayer
    return ffpyplayer.dep_bins


for binary_dir in _get_ffpyplayer_binary_dirs():
    binaries += [(binary_dir, '.')]  # Copy DLLs from these locations into top-level application directory.
