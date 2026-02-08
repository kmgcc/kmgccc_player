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

from PyInstaller.utils.hooks import collect_data_files, is_module_satisfies

# This was required with langchain < 1.0.0; in contemporary versions, the package does not contain any data files,
# so this should be effectively a no-op.
datas = collect_data_files('langchain')

# In langchain 1.2.1 the import logic for optional add-on packages was refactored, and direct imports in conditional
# blocks were replaced with dictionary-based look-up; see https://github.com/langchain-ai/langchain/pull/32813
# So now we need to use that same dictionary to explicitly collect the optional packages that happen to be installed
# in the build environment.
if is_module_satisfies('langchain >= 1.2.1'):
    from PyInstaller import isolated

    @isolated.decorate
    def get_optional_packages():
        packages = set()

        try:
            from langchain.chat_models.base import _SUPPORTED_PROVIDERS
            packages.update(package_name for package_name, *_ in _SUPPORTED_PROVIDERS.values())
        except Exception:
            pass

        try:
            from langchain.embeddings.base import _SUPPORTED_PROVIDERS
            packages.update(package_name for package_name, *_ in _SUPPORTED_PROVIDERS.values())
        except Exception:
            pass

        return sorted(packages)

    hiddenimports = get_optional_packages()
    warn_on_missing_hiddenimports = False
