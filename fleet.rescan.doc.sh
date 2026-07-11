#!/bin/bash
cd ~/repos && for r in scripts dennyrgood.github.io standing-up-llm google-photos; do

  (cd "$r" && git ls-files -s | sed "s|^|$r/|")

done > ~/fleet_git_baseline_NEW.txt

diff <(sort ~/fleet_git_baseline.txt) <(sort ~/fleet_git_baseline_NEW.txt)

