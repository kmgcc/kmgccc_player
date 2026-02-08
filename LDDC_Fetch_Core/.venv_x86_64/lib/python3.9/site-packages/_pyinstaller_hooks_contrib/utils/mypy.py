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

from _pyinstaller_hooks_contrib.compat import importlib_metadata


# Given the distribution name, find the top-level `mypyc` extension module belonging to that distribution. The said
# top-level module is called something like `30fcd23745efe32ce681__mypyc`; the prefix changes across different versions
# of the same distribution (and, of course, across different distributions). Therefore, we need to obtain the name by
# looking at distribution's list of files.
def find_mypyc_module_for_dist(dist_name):
    try:
        dist = importlib_metadata.distribution(dist_name)
    except importlib_metadata.PackageNotFoundError:
        return []
    return [entry.name.split('.')[0] for entry in (dist.files or []) if '__mypyc' in entry.name]
