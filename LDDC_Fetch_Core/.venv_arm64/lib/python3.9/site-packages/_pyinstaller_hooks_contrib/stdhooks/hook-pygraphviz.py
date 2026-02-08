# ------------------------------------------------------------------
# Copyright (c) 2021 PyInstaller Development Team.
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
import pathlib
import shutil

from PyInstaller import compat
from PyInstaller.depend import bindepend
from PyInstaller.utils.hooks import logger


def _collect_graphviz_files():
    binaries = []
    datas = []

    # A working `pygraphviz` installation requires graphviz programs in PATH. Attempt to resolve the `dot` executable to
    # see if this is the case.
    dot_binary = shutil.which('dot')
    if not dot_binary:
        logger.warning(
            "hook-pygraphviz: 'dot' program not found in PATH!"
        )
        return binaries, datas
    logger.info("hook-pygraphviz: found 'dot' program: %r", dot_binary)
    bin_dir = pathlib.Path(dot_binary).parent

    # Collect graphviz programs that might be called from `pygaphviz.agraph.AGraph`:
    # https://github.com/pygraphviz/pygraphviz/blob/pygraphviz-1.14/pygraphviz/agraph.py#L1330-L1348
    # On macOS and on Linux, several of these are symbolic links to a single executable.
    progs = (
        "neato",
        "dot",
        "twopi",
        "circo",
        "fdp",
        "nop",
        "osage",
        "patchwork",
        "gc",
        "acyclic",
        "gvpr",
        "gvcolor",
        "ccomps",
        "sccmap",
        "tred",
        "sfdp",
        "unflatten",
    )

    logger.debug("hook-pygraphviz: collecting graphviz program executables...")
    for program_name in progs:
        program_binary = shutil.which(program_name)
        if not program_binary:
            logger.debug("hook-pygaphviz: graphviz program %r not found!", program_name)
            continue

        # Ensure that the program executable was found in the same directory as the `dot` executable. This should
        # prevent us from falling back to other graphviz installations that happen to be in PATH.
        if pathlib.Path(program_binary).parent != bin_dir:
            logger.debug(
                "hook-pygraphviz: found program %r (%r) outside of directory %r - ignoring!",
                program_name, program_binary, str(bin_dir)
            )
            continue

        logger.debug("hook-pygraphviz: collecting graphviz program %r: %r", program_name, program_binary)
        binaries += [(program_binary, '.')]

    # Graphviz shared libraries should be automatically collected when PyInstaller performs binary dependency
    # analysis of the collected program executables as part of the main build process. However, we need to manually
    # collect plugins and their accompanying config file.
    logger.debug("hook-pygraphviz: looking for graphviz plugin directory...")
    if compat.is_win:
        # Under Windows, we have several installation variants:
        #  - official installers and builds from https://gitlab.com/graphviz/graphviz/-/releases
        #  - chocolatey
        #  - msys2
        #  - Anaconda
        # In all variants, the plugins and the config file are located in the `bin` directory, next to the program
        # executables.
        plugin_dir = bin_dir
        plugin_dest_dir = '.'  # Collect into top-level application directory.
        # Official builds and Anaconda use unversioned `gvplugin-{name}.dll` plugin names, while msys2 uses
        # versioned `libgvplugin-{name}-{version}.dll` plugin names (with "lib" prefix).
        plugin_pattern = '*gvplugin*.dll'
    else:
        # Perform binary dependency analysis on the `dot` executable to obtain the path to graphiz shared libraries.
        # These need to be in the library search path for the programs to work, or discoverable via run-paths
        # (e.g., Anaconda on Linux and macOS, Homebrew on macOS).
        graphviz_lib_candidates = ['cdt', 'gvc', 'cgraph']

        if hasattr(bindepend, 'get_imports'):
            # PyInstaller >= 6.0
            dot_imports = [path for name, path in bindepend.get_imports(dot_binary) if path is not None]
        else:
            # PyInstaller < 6.0
            dot_imports = bindepend.getImports(dot_binary)

        graphviz_lib_paths = [
            path for path in dot_imports
            if any(candidate in os.path.basename(path) for candidate in graphviz_lib_candidates)
        ]

        if not graphviz_lib_paths:
            logger.warning("hook-pygraphviz: could not determine location of graphviz shared libraries!")
            return binaries, datas

        graphviz_lib_dir = pathlib.Path(graphviz_lib_paths[0]).parent
        logger.debug("hook-pygraphviz: location of graphviz shared libraries: %r", str(graphviz_lib_dir))

        # Plugins should be located in `graphviz` directory next to shared libraries.
        plugin_dir = graphviz_lib_dir / 'graphviz'
        plugin_dest_dir = 'graphviz'  # Collect into graphviz sub-directory.

        if compat.is_darwin:
            plugin_pattern = '*gvplugin*.dylib'
        else:
            # Collect only versioned .so library files (for example, `/lib64/graphviz/libgvplugin_core.so.6` and
            # `/lib64/graphviz/libgvplugin_core.so.6.0.0`; the former usually being a symbolic link to the latter).
            # The unversioned .so library files (such as `lib64/graphviz/libgvplugin_core.so`), if available, are
            # meant for linking (and are usually installed as part of development package).
            plugin_pattern = '*gvplugin*.so.*'

    if not plugin_dir.is_dir():
        logger.warning("hook-pygraphviz: could not determine location of graphviz plugins!")
        return binaries, datas

    logger.info("hook-pygraphviz: collecting graphviz plugins from directory: %r", str(plugin_dir))

    binaries += [(str(file), plugin_dest_dir) for file in plugin_dir.glob(plugin_pattern)]
    datas += [(str(file), plugin_dest_dir) for file in plugin_dir.glob("config*")]  # e.g., `config6`

    return binaries, datas


binaries, datas = _collect_graphviz_files()
