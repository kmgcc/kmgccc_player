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

import sys

__version__ = '2026.0'
__maintainer__ = 'Legorooj, bwoodsend'
__uri__ = 'https://github.com/pyinstaller/pyinstaller-hooks-contrib'


def get_hook_dirs():
    import os
    hooks_dir = os.path.dirname(__file__)
    return [
        # Required because standard hooks are in sub-directory instead of the top-level hooks directory.
        os.path.join(hooks_dir, 'stdhooks'),
        # pre_* and run-time hooks
        hooks_dir,
    ]


# Several packages for which provide hooks are involved in deep dependency chains when various optional dependencies are
# installed in the environment, and their analysis typically requires recursion limit that exceeds the default 1000.
# Therefore, automatically raise the recursion limit to at least 5000. This alleviates the need to do so on per-hook
# basis.
if (sys.platform.startswith('win') or sys.platform == 'cygwin') and sys.version_info < (3, 11):
    # The recursion limit test in PyInstaller main repository seems to push the recursion level to the limit; and if the
    # limit is set to 5000, this crashes python 3.8 - 3.10 on Windows and 3.9 that is (at the time of writing) available
    # under Cygwin. Further investigation revealed that Windows builds of python 3.8 and 3.10 handle recursion up to
    # level ~2075, while the practical limit for 3.9 is between 1950 and 1975. Therefore, for affected combinations of
    # platforms and python versions, use a conservative limit of 1900 - if only to avoid issues with the recursion limit
    # test in the main PyInstaller repository...
    new_recursion_limit = 1900
else:
    new_recursion_limit = 5000

if sys.getrecursionlimit() < new_recursion_limit:
    sys.setrecursionlimit(new_recursion_limit)
