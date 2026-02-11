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

from PyInstaller import compat
from PyInstaller.utils.hooks import collect_dynamic_libs, collect_data_files

if compat.is_win:
    # On Windows, pymeshlab wheel seems to include Qt libraries and plugins (and their dependencies, as well as meshlab
    # plugins), as well as some of data files (such as translation files); all in the top-level package directory.
    binaries = collect_dynamic_libs('pymeshlab')
    datas = collect_data_files('pymeshlab')
elif compat.is_linux:
    # On linux, only Qt libraries and plugins (and their dependencies, as well as meshlab plugins) seem to be included;
    # all in lib subdir.
    # NOTE: collect_dynamic_libs() does not collect versioned .so files; those are picked up by collect_data_files().
    binaries = collect_dynamic_libs('pymeshlab.lib') + collect_data_files('pymeshlab.lib')
elif compat.is_darwin:
    # On macOS, Frameworks sub-directory contains Qt .framework bundles and other shared libraries, all of which seem
    # to be picked up by binary dependency analysis. Avoid explicitly collecting anything from there to avoid
    # interfering with PyInstaller's attempts to fix-up .framework bundle structure (see pyinstaller/pyinstaller#9335).
    # The plugins for both meshlab and Qt are in PlugIns directory, and we need to collect those.
    binaries = collect_dynamic_libs('pymeshlab.PlugIns')

# On linux, prevent binary dependency analysis from generating symbolic links for bundles shared libraries to the
# top-level application directory. For some god-forsaken reason, the wheel includes a copy of python shared library,
# which might actually be ABI incompatible with version of python that frozen application is built with (for example,
# libpython3.13.so.1.0 shipped with pymeshlab 2025.7 causes `undefined symbol: _Py_GetExecutor` in `_opcode` extension
# collected from Fedora-provided python 3.13.11).
if compat.is_linux:
    bindepend_symlink_suppression = [
        '**/pymeshlab/lib/*',
    ]
