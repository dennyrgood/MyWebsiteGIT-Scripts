# If you hand-edit test_sync_to_fleetnas.sh from Windows (e.g. Notepad, this repo's
# editor tools), it gets saved with CRLF line endings, which breaks the #!/bin/bash
# shebang under WSL ("cannot execute: required file not found"). Strip them first:
#   wsl -d Ubuntu -- bash -c "sed -i 's/\r$//' /mnt/d/repos/scripts/AmsterdamDesktop/test_sync_to_fleetnas.sh"
wsl -d Ubuntu -- bash -c "/mnt/d/repos/scripts/AmsterdamDesktop/test_sync_to_fleetnas.sh"
