#!/bin/bash
cd "$(dirname "$0")"
# Combine and run
cat OptimizedAppleMusicBridge.swift Phase1Test.swift > /tmp/phase1_full.swift
xcrun swift /tmp/phase1_full.swift
