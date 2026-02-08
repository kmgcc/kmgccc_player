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

# Hook for Segment Anything Model 2 (SAM 2): https://pypi.org/project/sam2

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

# Collect config .yaml files.
datas = collect_data_files('sam2')

# Ensure that all indirectly-imported modules are collected (e.g., `sam2.modeling.backbones`).
hiddenimports = collect_submodules('sam2')

# Due to use of `torch.script`, we need to collect source .py files for `sam2`. The `sam2/__init__.py` also seems to be
# required by `hydra`. Furthermore, the source-based introspection attempts to load the source of stdlib `enum` module.
# The module collection mode support and run-time discovery of source .py files for modules that are collected into
# `base_library.zip` archive was added in pyinstaller/pyinstaller#8971 (i.e., PyInstaller > 6.11.1).
module_collection_mode = {
    'sam2': 'pyz+py',
    'enum': 'pyz+py',  # requires PyInstaller > 6.11.1; no-op in earlier versions
}
