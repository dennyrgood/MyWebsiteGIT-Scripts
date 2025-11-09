#!/bin/bash

# Function to generate commit message from changes
generate_commit_message() {
    local branch="$1"
    
    # Get statistics
    local added=$(git diff --staged --numstat | awk '{sum+=$1} END {print sum+0}')
    local deleted=$(git diff --staged --numstat | awk '{sum+=$2} END {print sum+0}')
    local files_changed=$(git diff --staged --name-only | wc -l | tr -d ' ')
    
    # Get file types changed
    local file_list=$(git diff --staged --name-only)
    
    # Categorize changes by file type
    local has_scripts=$(echo "$file_list" | grep -E '\.(sh|bash)$' | wc -l | tr -d ' ')
    local has_code=$(echo "$file_list" | grep -E '\.(js|py|rb|java|go|rs|c|cpp|ts|tsx|jsx)$' | wc -l | tr -d ' ')
    local has_config=$(echo "$file_list" | grep -E '\.(json|yaml|yml|toml|ini|conf|env)$' | wc -l | tr -d ' ')
    local has_docs=$(echo "$file_list" | grep -E '\.(md|txt|rst|doc)$' | wc -l | tr -d ' ')
    local has_styles=$(echo "$file_list" | grep -E '\.(css|scss|sass|less)$' | wc -l | tr -d ' ')
    
    # Get change types (Added, Modified, Deleted)
    local change_types=$(git diff --staged --name-status | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')
    
    # Build message parts
    local msg_parts=()
    
    # Main action verb based on change types
    if [[ "$change_types" =~ "D" && ! "$change_types" =~ "A|M" ]]; then
        msg_parts+=("Remove")
    elif [[ "$change_types" =~ "A" && ! "$change_types" =~ "M|D" ]]; then
        msg_parts+=("Add")
    elif [[ "$change_types" =~ "M" && ! "$change_types" =~ "A|D" ]]; then
        msg_parts+=("Update")
    else
        msg_parts+=("Modify")
    fi
    
    # What was changed
    if [ "$has_scripts" -gt 0 ]; then
        msg_parts+=("scripts")
    fi
    if [ "$has_code" -gt 0 ]; then
        msg_parts+=("code")
    fi
    if [ "$has_config" -gt 0 ]; then
        msg_parts+=("config")
    fi
    if [ "$has_docs" -gt 0 ]; then
        msg_parts+=("docs")
    fi
    if [ "$has_styles" -gt 0 ]; then
        msg_parts+=("styles")
    fi
    
    # If no specific type detected, use generic
    if [ ${#msg_parts[@]} -eq 1 ]; then
        msg_parts+=("files")
    fi
    
    # Join message parts
    local main_msg=$(IFS=' '; echo "${msg_parts[*]}")
    
    # Add file count detail
    local detail="($files_changed file"
    [ "$files_changed" -ne 1 ] && detail="${detail}s"
    detail="$detail, +$added/-$deleted lines)"
    
    echo "$main_msg $detail"
}

# Example usage in sync-this.sh context:
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Stage all changes
git add -A

# Check if there are changes
if ! git diff --staged --quiet; then
    # Generate automatic message
    AUTO_MESSAGE=$(generate_commit_message "$CURRENT_BRANCH")
    DEFAULT_MESSAGE="$AUTO_MESSAGE on branch: $CURRENT_BRANCH"
    
    echo "Detected changes:"
    git diff --staged --stat
    echo ""
    echo "Suggested commit message:"
    echo "  → $DEFAULT_MESSAGE"
    echo ""
    echo "Press Enter to use this message, or type your own:"
    read -r USER_MESSAGE
    
    if [ -z "$USER_MESSAGE" ]; then
        COMMIT_MESSAGE="$DEFAULT_MESSAGE"
    else
        COMMIT_MESSAGE="$USER_MESSAGE"
    fi
    
    echo "Committing with: \"$COMMIT_MESSAGE\""
    git commit -m "$COMMIT_MESSAGE"
else
    echo "No changes to commit"
fi
