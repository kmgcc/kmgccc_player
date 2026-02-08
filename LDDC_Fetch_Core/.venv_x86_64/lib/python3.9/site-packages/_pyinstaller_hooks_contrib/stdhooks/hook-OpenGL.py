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
"""
Hook for PyOpenGL 3.x versions from 3.0.0b6 up. Previous versions have a
plugin system based on pkg_resources which is problematic to handle correctly
under pyinstaller; 2.x versions used to run fine without hooks, so this one
shouldn't hurt.
"""

from PyInstaller.compat import is_win, is_darwin
from PyInstaller.utils.hooks import collect_data_files, collect_submodules


# PlatformPlugin performs a conditional import based on os.name and
# sys.platform. PyInstaller misses this so let's add it ourselves...
if is_win:
    hiddenimports = ['OpenGL.platform.win32']
elif is_darwin:
    hiddenimports = ['OpenGL.platform.darwin']
# Use glx for other platforms (Linux, ...)
else:
    hiddenimports = ['OpenGL.platform.glx']

# Arrays modules are needed too.
hiddenimports += collect_submodules('OpenGL.arrays')

# PyOpenGL 3.x uses ctypes to load DLL libraries. PyOpenGL windows installer
# adds necessary dll files to
#   DLL_DIRECTORY = os.path.join( os.path.dirname( OpenGL.__file__ ), 'DLLS')
# PyInstaller is not able to find these dlls. Just include them all as data
# files.
if is_win:
    datas = collect_data_files('OpenGL')
