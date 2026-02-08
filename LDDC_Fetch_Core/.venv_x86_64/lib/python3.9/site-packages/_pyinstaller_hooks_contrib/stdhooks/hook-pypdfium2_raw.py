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

from PyInstaller.utils.hooks import collect_dynamic_libs, collect_data_files

# Collect the bundled pdfium shared library.
binaries = collect_dynamic_libs('pypdfium2_raw')

# Collect `version.json`.
datas = collect_data_files("pypdfium2_raw")
