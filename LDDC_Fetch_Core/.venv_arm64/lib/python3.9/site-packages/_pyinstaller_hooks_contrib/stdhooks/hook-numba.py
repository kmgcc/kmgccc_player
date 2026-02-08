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
#
# NumPy aware dynamic Python compiler using LLVM
# https://github.com/numba/numba
#
# Tested with:
# numba 0.26 (Anaconda 4.1.1, Windows), numba 0.28 (Linux)

from PyInstaller.utils.hooks import is_module_satisfies

excludedimports = ["IPython", "scipy"]
hiddenimports = ["llvmlite"]

# numba 0.59.0 updated its vendored version of cloudpickle to 3.0.0; this version keeps `cloudpickle_fast` module
# around for backward compatibility with existing pickled data, but does not import it directly anymore.
if is_module_satisfies("numba >= 0.59.0"):
    hiddenimports += ["numba.cloudpickle.cloudpickle_fast"]

# numba 0.61 introduced new type system with several dynamic redirects using `numba.core.utils._RedirectSubpackage`;
# depending on the run-time value of `numba.config.USE_LEGACY_TYPE_SYSTEM`, either "old" or "new" module variant is
# loaded. All of these seem to be loaded when `numba` is imported, so there is no need for finer granularity. Also,
# as the config value might be manipulated at run-time (e.g., via environment variable), we need to collect both old
# and new module variants.
# numba 0.62 reverted the change, removing the new type system.
if is_module_satisfies("numba >= 0.61.0rc1, < 0.62.0rc1"):
    # NOTE: `numba.core.typing` is also referenced indirectly via `_RedirectSubpackage`, but we do not need a
    # hidden import entry for it, because we have entries for its submodules.
    modules_old = [
        'numba.core.datamodel.old_models',
        'numba.core.old_boxing',
        'numba.core.types.old_scalars',
        'numba.core.typing.old_builtins',
        'numba.core.typing.old_cmathdecl',
        'numba.core.typing.old_mathdecl',
        'numba.cpython.old_builtins',
        'numba.cpython.old_hashing',
        'numba.cpython.old_mathimpl',
        'numba.cpython.old_numbers',
        'numba.cpython.old_tupleobj',
        'numba.np.old_arraymath',
        'numba.np.random.old_distributions',
        'numba.np.random.old_random_methods',
    ]
    modules_new = [name.replace('.old_', '.new_') for name in modules_old]
    hiddenimports += modules_old + modules_new
