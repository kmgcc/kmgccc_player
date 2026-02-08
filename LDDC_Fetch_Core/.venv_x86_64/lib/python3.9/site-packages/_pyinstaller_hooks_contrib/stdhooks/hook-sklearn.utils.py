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

from PyInstaller.utils.hooks import is_module_satisfies

hiddenimports = ['sklearn.utils._cython_blas']

# As of scikit-learn 1.7.1, the `sklearn.utils._isfinite` extension started to depend on newly-introduced
# `sklearn._cyutility`.
if is_module_satisfies('scikit-learn >= 1.7.1'):
    hiddenimports += ['sklearn._cyutility']
