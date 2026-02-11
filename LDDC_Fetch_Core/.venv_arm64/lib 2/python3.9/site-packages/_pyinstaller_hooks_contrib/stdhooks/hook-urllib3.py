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

from PyInstaller.utils.hooks import collect_submodules, is_module_satisfies

# If this is `urllib3` from `urllib3-future`, collect submodules in order to avoid missing modules due to indirect
# imports. With `urllib3` from "classic" `urllib3`, this does not seem to be necessary.
if is_module_satisfies("urllib3-future"):
    hiddenimports = collect_submodules("urllib3")
