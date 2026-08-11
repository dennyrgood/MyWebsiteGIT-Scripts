#!/bin/bash

echo "Changing directory to /Users/dennishmathes/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI"
cd "/Users/dennishmathes/OneDrive/DropBoxReplacement/MathesDropBox/0ComfyUI"

# Replace the current shell process with a new instance of the interactive shell.
# This is the trick that ensures the directory change (cd) persists 
# after the script finishes, leaving you in the target directory.
exec "$SHELL" -i
