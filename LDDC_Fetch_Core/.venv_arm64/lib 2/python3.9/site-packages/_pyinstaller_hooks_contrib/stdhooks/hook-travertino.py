# ------------------------------------------------------------------
# Copyright (c) 2024 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

from PyInstaller.utils.hooks import copy_metadata

# Prevent this package from pulling `setuptools_scm` into frozen application, as it makes no sense in that context.
excludedimports = ["setuptools_scm"]

# Collect metadata to allow package to infer its version at run-time.
datas = copy_metadata("travertino")
