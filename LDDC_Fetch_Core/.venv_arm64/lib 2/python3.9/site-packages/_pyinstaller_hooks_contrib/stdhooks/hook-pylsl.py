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
# ------------------------------------------------------------------

import os
from PyInstaller.utils.hooks import logger, isolated


def find_library():
    # Try importing pylsl - this will fail if the shared library is unavailable.
    try:
        import pylsl  # noqa: F401
    except Exception:
        return None

    # Return the path to shared library that is used by pylsl.
    try:
        from pylsl.lib import lib as cdll  # pylsl >= 0.17.0
    except ImportError:
        from pylsl.pylsl import lib as cdll  # older versions

    return cdll._name


# whenever a hook needs to load a 3rd party library, it needs to be done in an isolated subprocess
libfile = isolated.call(find_library)

if libfile:
    # add the liblsl library to the binaries
    # it gets packaged in pylsl/lib, which is where pylsl will look first
    binaries = [(libfile, os.path.join('pylsl', 'lib'))]
else:
    logger.warning("liblsl shared library not found - pylsl will likely fail to work!")
    binaries = []
