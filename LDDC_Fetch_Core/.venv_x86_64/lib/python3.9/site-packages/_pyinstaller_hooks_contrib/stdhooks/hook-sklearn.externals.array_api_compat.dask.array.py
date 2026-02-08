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

# These hidden imports are required due to the following statements found in the package's `__init__.py`:
# ```
# __import__(__package__ + '.linalg')
# __import__(__package__ + '.fft')
# ```
hiddenimports = [
    'sklearn.externals.array_api_compat.dask.array.fft',
    'sklearn.externals.array_api_compat.dask.array.linalg',
]
