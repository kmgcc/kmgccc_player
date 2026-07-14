#!/usr/bin/env python3
# PyInstaller entry point for LDDC server
# This file uses absolute imports to avoid "relative import with no known parent package"

import sys
from lddc_fetch_core.server import main

if __name__ == "__main__":
    sys.exit(main())
