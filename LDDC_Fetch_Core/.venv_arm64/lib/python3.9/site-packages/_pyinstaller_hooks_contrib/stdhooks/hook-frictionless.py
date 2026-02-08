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

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

# Collect data files in frictionless/assets
datas = collect_data_files('frictionless')

# Collect modules from `frictionless.plugins` (programmatic imports).
hiddenimports = collect_submodules('frictionless.plugins')
