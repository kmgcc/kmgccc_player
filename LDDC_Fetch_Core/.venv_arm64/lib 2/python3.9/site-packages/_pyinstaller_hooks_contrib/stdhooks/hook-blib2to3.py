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
from PyInstaller.utils.hooks import collect_submodules, collect_data_files
from _pyinstaller_hooks_contrib.utils.mypy import find_mypyc_module_for_dist

hiddenimports = [
    # `black` (or rather, its `blib2to3` library) uses `mypy`, and includes a top-level module with
    # dynamically-generated name prefix; for example, `30fcd23745efe32ce681__mypyc`.
    *find_mypyc_module_for_dist('black'),
    'dataclasses',
    'pkgutil',
    'tempfile',
    *collect_submodules('blib2to3')
]

# Ensure that data files, such as `PatternGrammar.txt` and `Grammar.txt`, are collected.
datas = collect_data_files('blib2to3')
