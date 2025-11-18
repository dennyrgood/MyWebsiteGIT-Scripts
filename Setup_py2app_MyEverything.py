#!/usr/bin/env python3

"""
Setup script for creating a macOS application bundle using py2app.

Usage:
    python setup.py py2app

This will create a standalone .app bundle in the dist/ folder.
"""

from setuptools import setup

APP = ['MyEverything.py']
DATA_FILES = []
OPTIONS = {
    'argv_emulation': False,
    'packages': ['tkinter'],
    'iconfile': 'app_icon.icns',  # Optional: Add your custom icon file
    'plist': {
        'CFBundleName': 'MyEverything',
        'CFBundleDisplayName': 'MyEverything',
        'CFBundleGetInfoString': 'macOS Find GUI',
        'CFBundleIdentifier': 'com.myeverything.app',
        'CFBundleVersion': '1.0.0',
        'CFBundleShortVersionString': '1.0.0',
        'NSHumanReadableCopyright': 'Copyright © 2025',
    }
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
