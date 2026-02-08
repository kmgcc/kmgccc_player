# ------------------------------------------------------------------
# Copyright (c) 2020 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

from PyInstaller import isolated


# This is necessary because on first import, `wx.lib.activex` generates .tlb file for `comtypes`, unless running in a
# frozen application (in which case, the .tlb file is expected to exist already). So if we are building in a completely
# clean python environment (for example, in a CI/CD pipeline), we need to ensure that .tlb file is generated.
@isolated.decorate
def _ensure_tlb_file_exists():
    try:
        import wx.lib.activex  # noqa: F401
    except Exception:
        pass


_ensure_tlb_file_exists()
