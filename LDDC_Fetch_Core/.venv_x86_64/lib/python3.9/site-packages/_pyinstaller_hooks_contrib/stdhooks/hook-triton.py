# ------------------------------------------------------------------
# Copyright (c) 2023 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ---------------------------------------------------

from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules, is_module_satisfies

hiddenimports = []
datas = []

# Ensure that triton/_C/libtriton.so is collected
binaries = collect_dynamic_libs('triton')

# triton has a JIT module that requires its source .py files. For some god-forsaken reason, this JIT module
# (`triton.runtime.jit` attempts to directly read the contents of file pointed to by its `__file__` attribute (assuming
# it is a source file). Therefore, `triton.runtime.jit` must not be collected into PYZ. Same goes for `compiler` and
# `language` sub-packages.
module_collection_mode = {
    'triton': 'pyz+py',
    'triton.runtime.jit': 'py',
    'triton.compiler': 'py',
    'triton.language': 'py',
}

# triton 3.0.0 introduced `triton.backends` sub-package with backend-specific files.
if is_module_satisfies('triton >= 3.0.0'):
    # Collect backend sub-modules/packages.
    hiddenimports += collect_submodules('triton.backends')

    # At the time of writing (triton v3.1.0), `triton.backends.amd` is a namespace package, and is not captured by the
    # above `collect_submodules` call.
    hiddenimports += collect_submodules('triton.backends.amd')

    # Collect ptxas compiler files from `triton/backends/nvidia`, and the HIP/ROCm files from `triton/backends/amd`.
    datas += collect_data_files('triton.backends')
else:
    # Collect ptxas compiler files from triton/third_party/cuda directory. Strictly speaking, the ptxas executable from
    # bin directory should be collected as a binary, but in this case, it makes no difference (plus, PyInstaller >= 6.0
    # has automatic binary-vs-data reclassification).
    datas += collect_data_files('triton.third_party.cuda')
