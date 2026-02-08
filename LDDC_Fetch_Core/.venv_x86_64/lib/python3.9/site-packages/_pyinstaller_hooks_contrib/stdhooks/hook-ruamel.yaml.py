# ------------------------------------------------------------------
# Copyright (c) 2024 PyInstaller Development Team.
#
# This file is distributed under the terms of the GNU General Public
# License (version 2.0 or later).
#
# The full license is available in LICENSE, distributed with
# this software.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ------------------------------------------------------------------

# `ruamel.yaml` offers several optional plugins that can be installed via additional packages
# (e.g., `runamel.yaml.string`). Unfortunately, the discovery of these plugins is predicated on their `__plug_in__.py`
# files being visible on filesystem.
# See: https://sourceforge.net/p/ruamel-yaml/code/ci/0bef9fa8b3c43637cd90ce3f2e299e81c2122128/tree/main.py#l757

import pathlib

from PyInstaller.utils.hooks import get_module_file_attribute, logger

ruamel_path = pathlib.Path(get_module_file_attribute('ruamel.yaml')).parent

plugin_files = ruamel_path.glob('*/__plug_in__.py')
plugin_names = [plugin_file.parent.name for plugin_file in plugin_files]
logger.debug("hook-ruamel.yaml: found plugins: %r", plugin_names)

# Add `__plug_in__` modules to hiddenimports to ensure they are collected and scanned for imports. This also implicitly
# collects the plugin's `__init__` module.
plugin_modules = [f"ruamel.yaml.{plugin_name}.__plug_in__" for plugin_name in plugin_names]

hiddenimports = plugin_modules

# Collect the plugins' `__plug_in__` modules both as byte-compiled .pyc in PYZ archive (to be actually loaded) and
# source .py file (which allows plugin to be discovered).
module_collection_mode = {
    plugin_module: "pyz+py"
    for plugin_module in plugin_modules
}
