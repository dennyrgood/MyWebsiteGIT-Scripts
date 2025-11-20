for dir in */ ; do
  if [ -d "$dir/.git" ]; then
    echo "Processing $dir..."
    cd "$dir"

    # 1. Untrack all .DS_Store files (using the robust find command)
    find . -name .DS_Store -print0 | xargs -0 git rm --cached --ignore-unmatch

    # 2. Commit the removal
    git commit -m "Stop tracking .DS_Store files"

    # 3. Push the change (Optional, but usually needed)
    # git push

    cd ..
  fi
done
