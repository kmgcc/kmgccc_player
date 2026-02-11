#-----------------------------------------------------------------------------
# Copyright (c) 2005-2020, PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#-----------------------------------------------------------------------------
"""
PyWin32 package 'win32com' extends its __path__ attribute with win32comext
directory and thus PyInstaller is not able to find modules in it. For example
module 'win32com.shell' is in reality 'win32comext.shell'.

>>> win32com.__path__
['win32com', 'C:\\Python27\\Lib\\site-packages\\win32comext']

"""

import os

from PyInstaller import compat
from PyInstaller import isolated
from PyInstaller.utils.hooks import logger


@isolated.decorate
def _get_win32com_file():
    try:
        import win32com
        return win32com.__file__
    except Exception:
        return None


def pre_safe_import_module(api):
    if not compat.is_win or compat.is_cygwin:
        return

    win32com_file = _get_win32com_file()
    if not win32com_file:
        logger.debug('win32com: module not available')
        return  # win32com unavailable
    win32com_dir = os.path.dirname(win32com_file)
    comext_dir = os.path.join(os.path.dirname(win32com_dir), 'win32comext')
    logger.debug('win32com: extending __path__ with dir %r' % comext_dir)
    # Append the __path__ where PyInstaller will look for 'win32com' modules.'
    api.append_package_path(comext_dir)
