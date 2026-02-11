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

from PyInstaller import isolated

hiddenimports = [
    "sentry_sdk.integrations.stdlib",
    "sentry_sdk.integrations.excepthook",
    "sentry_sdk.integrations.dedupe",
    "sentry_sdk.integrations.atexit",
    "sentry_sdk.integrations.modules",
    "sentry_sdk.integrations.argv",
    "sentry_sdk.integrations.logging",
    "sentry_sdk.integrations.threading",
]


@isolated.decorate
def _get_integration_modules():
    import sentry_sdk.integrations as si

    # _AUTO_ENABLING_INTEGRATIONS is a list of strings with default enabled integrations
    # https://github.com/getsentry/sentry-python/blob/c6b6f2086b58ffc674df5c25a600b8a615079fb5/sentry_sdk/integrations/__init__.py#L54-L66
    integrations = getattr(si, '_AUTO_ENABLING_INTEGRATIONS', [])

    # The list contains fully-qualified class names; turn them into module names by removing the last component.
    return [integration_name.rsplit('.', maxsplit=1)[0] for integration_name in integrations]


hiddenimports += _get_integration_modules()
