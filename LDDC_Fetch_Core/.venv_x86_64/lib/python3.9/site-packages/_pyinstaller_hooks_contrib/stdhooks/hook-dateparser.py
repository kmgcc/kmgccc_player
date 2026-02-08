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

from PyInstaller.utils.hooks import collect_data_files

# Ensure that `dateparser/data/dateparser_tz_cache.pkl` data file is collected. Applicable to dateparser >= v1.2.2;
# earlier releases have no data files, so this call returns empty list.
datas = collect_data_files('dateparser')
