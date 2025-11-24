#!/bin/bash

git status --porcelain | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//'
