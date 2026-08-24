#!/bin/bash

cd ~/.hammerspoon
sed -E 's/(keyStrokes\(")[^"]*(")/\1REDACTED\2/g' init.lua > init.lua.safe
diff init.lua init.lua.safe
