#-----------------------------------------------------------------------------
# Copyright (c) 2025, PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#-----------------------------------------------------------------------------

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

# Collect submodules of distributed.http, many of which are imported indirectly.
hiddenimports = collect_submodules("distributed.http")

# Collect data files (distributed.yaml, distributed-schema.yaml, templates).
datas = collect_data_files("distributed")

# `distributed.dashboard.components.scheduler` attempts to refer to data files relative to its parent directory, but
# with non-normalized '..' elements in the path (e.g., `_MEIPASS/distributed/dashboard/components/../theme.yaml`). On
# POSIX systems, such paths are treated as non-existent if a component does not exist, even if the file exists at the
# normalized location (i.e., if `_MEIPASS/distributed/dashboard/theme.yaml` file exists but
# `_MEIPASS/distributed/dashboard/components` directory does not). As a work around, collect source .py files from
# `distributed.dashboard.components` to ensure existence of the `components` directory.
module_collection_mode = {
    'distributed.dashboard.components': 'pyz+py',
}
