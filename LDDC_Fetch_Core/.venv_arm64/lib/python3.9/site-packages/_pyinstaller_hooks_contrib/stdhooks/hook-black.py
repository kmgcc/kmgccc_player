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

# These are all imported from cythonized extensions.
hiddenimports = [
    'json',
    'platform',
    'click',
    'mypy_extensions',
    'pathspec',
    '_black_version',
    'platformdirs',
    *collect_submodules('black'),
    # blib2to3.pytree, blib2to3.pygen, various submodules from blib2to3.pgen2; best to just collect all submodules.
    *collect_submodules('blib2to3'),
]

# Ensure that `black/resources/black.schema.json` is collected, in case someone tries to call `black.schema.get_schema`.
datas = collect_data_files('black')
