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
Hook for cryptography module from the Python Cryptography Authority.
"""

import os
import glob
import pathlib

from PyInstaller import compat
from PyInstaller import isolated
from PyInstaller.utils.hooks import (
    collect_submodules,
    copy_metadata,
    get_module_file_attribute,
    is_module_satisfies,
    logger,
)

# get the package data so we can load the backends
datas = copy_metadata('cryptography')

# Add the backends as hidden imports
hiddenimports = collect_submodules('cryptography.hazmat.backends')

# Add the OpenSSL FFI binding modules as hidden imports
hiddenimports += collect_submodules('cryptography.hazmat.bindings.openssl') + ['_cffi_backend']


# Include the cffi extensions as binaries in a subfolder named like the package.
# The cffi verifier expects to find them inside the package directory for
# the main module. We cannot use hiddenimports because that would add the modules
# outside the package.
# NOTE: this is not true anymore with PyInstaller >= 6.0, but we keep it like this for compatibility with 5.x series.
binaries = []
cryptography_dir = os.path.dirname(get_module_file_attribute('cryptography'))
for ext in compat.EXTENSION_SUFFIXES:
    ffimods = glob.glob(os.path.join(cryptography_dir, '*_cffi_*%s*' % ext))
    for f in ffimods:
        binaries.append((f, 'cryptography'))


# Check if `cryptography` is dynamically linked against OpenSSL >= 3.0.0. In that case, we might need to collect
# external OpenSSL modules, if OpenSSL was built with modules support. It seems the best indication of this is the
# presence of `ossl-modules` directory next to the OpenSSL shared library.
#
# NOTE: PyPI wheels ship with extensions statically linked against OpenSSL, so this is mostly catering alternative
# installation methods (Anaconda on all OSes, Homebrew on macOS, various linux distributions).
try:
    @isolated.decorate
    def _check_cryptography_openssl3():
        # Check if OpenSSL 3 is used.
        from cryptography.hazmat.backends.openssl.backend import backend
        openssl_version = backend.openssl_version_number()
        if openssl_version < 0x30000000:
            return False, None

        # Obtain path to the bindings module for binary dependency analysis. Under older versions of cryptography,
        # this was a separate `_openssl` module; in contemporary versions, it is `_rust` module.
        try:
            import cryptography.hazmat.bindings._openssl as bindings_module
        except ImportError:
            import cryptography.hazmat.bindings._rust as bindings_module

        return True, str(bindings_module.__file__)

    uses_openssl3, bindings_module = _check_cryptography_openssl3()
except Exception:
    logger.warning(
        "hook-cryptography: failed to determine whether cryptography is using OpenSSL >= 3.0.0", exc_info=True
    )
    uses_openssl3, bindings_module = False, None

if uses_openssl3:
    # Determine location of OpenSSL shared library, provided that extension module is dynamically linked against it.
    # This requires the new PyInstaller.bindepend API from PyInstaller >= 6.0.
    openssl_lib = None
    if is_module_satisfies("PyInstaller >= 6.0"):
        from PyInstaller.depend import bindepend

        if compat.is_win:
            SSL_LIB_NAME = 'libssl-3-x64.dll' if compat.is_64bits else 'libssl-3.dll'
        elif compat.is_darwin:
            SSL_LIB_NAME = 'libssl.3.dylib'
        else:
            SSL_LIB_NAME = 'libssl.so.3'

        linked_libs = bindepend.get_imports(bindings_module)
        openssl_lib = [
            # Compare the basename of lib_name, because lib_fullpath is None if we fail to resolve the library.
            lib_fullpath for lib_name, lib_fullpath in linked_libs if os.path.basename(lib_name) == SSL_LIB_NAME
        ]
        openssl_lib = openssl_lib[0] if openssl_lib else None
    else:
        logger.warning(
            "hook-cryptography: full support for cryptography + OpenSSL >= 3.0.0 requires PyInstaller >= 6.0"
        )

    # Check for presence of ossl-modules directory next to the OpenSSL shared library.
    if openssl_lib:
        logger.info("hook-cryptography: cryptography uses dynamically-linked OpenSSL: %r", openssl_lib)

        openssl_lib_dir = pathlib.Path(openssl_lib).parent

        # Collect whole ossl-modules directory, if it exists.
        ossl_modules_dir = openssl_lib_dir / 'ossl-modules'

        # Msys2/MinGW installations on Windows put the shared library into `bin` directory, but the modules are
        # located in `lib` directory. Account for that possibility.
        if not ossl_modules_dir.is_dir() and openssl_lib_dir.name == 'bin':
            ossl_modules_dir = openssl_lib_dir.parent / 'lib' / 'ossl-modules'

        # On Alpine linux, the true location of shared library is /lib directory, but the modules' directory is located
        # in /usr/lib instead. Account for that possibility.
        if not ossl_modules_dir.is_dir() and openssl_lib_dir == pathlib.Path('/lib'):
            ossl_modules_dir = pathlib.Path('/usr/lib/ossl-modules')

        if ossl_modules_dir.is_dir():
            logger.debug("hook-cryptography: collecting OpenSSL modules directory: %r", str(ossl_modules_dir))
            binaries.append((str(ossl_modules_dir), 'ossl-modules'))
    else:
        logger.info("hook-cryptography: cryptography does not seem to be using dynamically linked OpenSSL.")
