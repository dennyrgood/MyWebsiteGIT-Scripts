#!/bin/bash

echo "I am changing directories to SL"

# Change to the root web development directory using the HOME variable
cd "$HOME/repos/llm"

# Replace the current shell process with a new instance of the interactive shell.
# This is the trick that ensures the directory change (cd) persists
# after the script finishes, leaving you in the target directory.
exec "$SHELL" -i
