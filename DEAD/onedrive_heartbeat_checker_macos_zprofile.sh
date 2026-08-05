#cat ~/.zprofile 

# Setting PATH for Python 3.13
# The original version is saved in .zprofile.pysave
PATH="/Library/Frameworks/Python.framework/Versions/3.13/bin:${PATH}"
export PATH

eval "$(/opt/homebrew/bin/brew shellenv)"
pgrep -qf heartbeat_checker_macos || /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python /Users/dennishmathes/repos/scripts/onedrive_heartbeat_checker_macos.py &
