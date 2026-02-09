#!/bin/bash

set -euo pipefail

# Configuration
ORG=""
USER=""
PACKAGE_NAME="package"
PER_PAGE=100
DRY_RUN=false
SKIP_CONFIRMATION=false
DAYS_THRESHOLD=30

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --org)
            if [[ -n "$USER" ]]; then
                echo "Error: --org and --user are mutually exclusive" >&2
                exit 1
            fi
            ORG="$2"
            shift 2
            ;;
        --user)
            if [[ -n "$ORG" ]]; then
                echo "Error: --org and --user are mutually exclusive" >&2
                exit 1
            fi
            USER="$2"
            shift 2
            ;;
        --package)
            PACKAGE_NAME="$2"
            shift 2
            ;;
        --days)
            DAYS_THRESHOLD="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--org ORG | --user USER] [--package PACKAGE_NAME] [--days DAYS] [--dry-run] [--yes] [--help]"
            echo "  --org              GitHub organization name"
            echo "  --user             GitHub username"
            echo "  --package          Package name (default: $PACKAGE_NAME)"
            echo "  --days             Age threshold in days for tagged versions (default: $DAYS_THRESHOLD)"
            echo "  --dry-run          Show what would be deleted without actually deleting"
            echo "  --yes              Skip confirmation prompt"
            echo "  --help             Show this help message"
            echo ""
            echo "Note: --org and --user are mutually exclusive. One must be specified."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate that either --org or --user is specified
if [[ -z "$ORG" && -z "$USER" ]]; then
    echo "Error: Either --org or --user must be specified" >&2
    exit 1
fi

# Set the target and API path based on whether we're using org or user
if [[ -n "$ORG" ]]; then
    TARGET="$ORG"
    API_PATH="/orgs/$ORG"
    TARGET_TYPE="organization"
else
    TARGET="$USER"
    API_PATH="/users/$USER"
    TARGET_TYPE="user"
fi

# Check if gh CLI is installed and authenticated
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed" >&2
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "Error: Not authenticated with GitHub CLI. Run 'gh auth login' first." >&2
    exit 1
fi

# Check for delete:packages scope
# auth_scopes=$(gh auth status 2>&1)
# if ! echo "$auth_scopes" | grep --quiet --extended-regexp "(delete:packages|write:packages)"; then
#     echo "Error: GitHub token lacks required scope. Need 'delete:packages' or 'write:packages'." >&2
#     echo "       Run 'gh auth refresh --scopes delete:packages' to add the scope." >&2
#     exit 1
# fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed" >&2
    exit 1
fi

# ========== UTILITY FUNCTIONS ==========

# Get versions for a specific page
get_versions_page() {
    local page=$1
    gh api \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        "$API_PATH/packages/container/$PACKAGE_NAME/versions?per_page=$PER_PAGE&page=$page"
}

# Delete a version
delete_version() {
    local version_id=$1
    local description="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would delete version ID: $version_id ($description)"
        return 0
    fi

    echo "Deleting version ID: $version_id ($description)"
    if gh api \
        --method DELETE \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        "$API_PATH/packages/container/$PACKAGE_NAME/versions/$version_id" 2> /dev/null; then
        echo "Successfully deleted version ID: $version_id"
        return 0
    else
        echo "Failed to delete version ID: $version_id" >&2
        return 1
    fi
}

# Check if a date is older than threshold
is_older_than_threshold() {
    local date_str="$1"
    local threshold_seconds=$((DAYS_THRESHOLD * 24 * 60 * 60))
    local current_timestamp
    local version_timestamp

    current_timestamp=$(date +%s)
    if ! version_timestamp=$(date --date "$date_str" +%s 2> /dev/null); then
        echo "Warning: Could not parse date: $date_str" >&2
        return 1
    fi

    local age_seconds=$((current_timestamp - version_timestamp))
    [[ $age_seconds -gt $threshold_seconds ]]
}

# ========== PHASE 1: COLLECT ALL VERSION DATA ==========

echo "Querying container versions for $TARGET_TYPE $TARGET, package $PACKAGE_NAME..."
echo "Will delete tagged versions older than $DAYS_THRESHOLD days..."

# Collect all version IDs to delete
untagged_versions=()
old_tagged_versions=()
old_tagged_descriptions=()
page=1

while true; do
    echo "Fetching page $page..."

    response=$(get_versions_page $page)

    if [[ -z "$response" ]]; then
        break
    fi

    if echo "$response" | jq --exit-status '.message' > /dev/null 2>&1; then
        echo "Error: $(echo "$response" | jq --raw-output '.message')" >&2
        exit 1
    fi

    version_count=$(echo "$response" | jq '. | length')
    if [[ "$version_count" -eq 0 ]]; then
        break
    fi

    # Process each version individually
    while IFS= read -r version; do
        [[ -z "$version" ]] && continue

        version_id=$(echo "$version" | jq --raw-output '.id')
        tags=$(echo "$version" | jq --compact-output '.metadata.container.tags')
        created_at=$(echo "$version" | jq --raw-output '.created_at')
        updated_at=$(echo "$version" | jq --raw-output '.updated_at')

        # Check for untagged versions
        if echo "$tags" | jq --exit-status '. == []' > /dev/null 2>&1; then
            untagged_versions+=("$version_id")
        else
            # Check if tagged version is old enough
            # Use updated_at if available, otherwise fall back to created_at
            check_date="$updated_at"
            if [[ "$check_date" == "null" || -z "$check_date" ]]; then
                check_date="$created_at"
            fi

            if [[ "$check_date" != "null" && -n "$check_date" ]]; then
                if is_older_than_threshold "$check_date"; then
                    tag_list=$(echo "$tags" | jq --raw-output '.[]' | tr '\n' ',' | sed 's/,$//')
                    old_tagged_versions+=("$version_id")
                    old_tagged_descriptions+=("tagged: $tag_list (from $check_date)")
                fi
            fi
        fi
    done <<< "$(echo "$response" | jq --compact-output '.[]')"

    # Check if we got a full page (if less than PER_PAGE, we're done)
    if [[ $version_count -lt $PER_PAGE ]]; then
        break
    fi

    ((++page))
done

# ========== PHASE 2: SUMMARY AND CONFIRMATION ==========

echo ""
echo "=========================================="
echo "           CLEANUP SUMMARY"
echo "=========================================="
echo ""
echo "Untagged versions:         ${#untagged_versions[@]}"
echo "Old tagged versions:       ${#old_tagged_versions[@]}"
echo ""

total_to_delete=$((${#untagged_versions[@]} + ${#old_tagged_versions[@]}))

if [[ ${#untagged_versions[@]} -gt 0 ]]; then
    echo "--- Untagged version IDs ---"
    printf '  %s\n' "${untagged_versions[@]}"
    echo ""
fi

if [[ ${#old_tagged_versions[@]} -gt 0 ]]; then
    echo "--- Old tagged versions ---"
    for i in "${!old_tagged_versions[@]}"; do
        echo "  ${old_tagged_versions[$i]}: ${old_tagged_descriptions[$i]}"
    done
    echo ""
fi

if [[ $total_to_delete -eq 0 ]]; then
    echo "No versions to delete."
    exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would delete $total_to_delete versions total"
fi

# ========== PHASE 3: DELETION ==========

if [[ "$DRY_RUN" == "false" && "$SKIP_CONFIRMATION" == "false" ]]; then
    echo ""
    read -p "Are you sure you want to delete $total_to_delete versions? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deletion cancelled."
        exit 0
    fi
fi

echo ""
echo "=== STARTING DELETION ==="

deleted_count=0
failed_count=0
current=0

# Delete untagged versions
for version_id in "${untagged_versions[@]}"; do
    ((++current))
    echo "[$current/$total_to_delete] Deleting version $version_id..."
    if delete_version "$version_id" "untagged"; then
        ((++deleted_count)) || true
    else
        ((++failed_count)) || true
    fi
done

# Delete old tagged versions
for i in "${!old_tagged_versions[@]}"; do
    ((++current))
    echo "[$current/$total_to_delete] Deleting version ${old_tagged_versions[$i]}..."
    if delete_version "${old_tagged_versions[$i]}" "${old_tagged_descriptions[$i]}"; then
        ((++deleted_count)) || true
    else
        ((++failed_count)) || true
    fi
done

# ========== FINAL SUMMARY ==========

echo ""
echo "=========================================="
echo "           CLEANUP COMPLETE"
echo "=========================================="
if [[ "$DRY_RUN" == "false" ]]; then
    echo "Successfully deleted: $deleted_count"
    if [[ $failed_count -gt 0 ]]; then
        echo "Failed to delete:     $failed_count"
    fi
else
    echo "[DRY RUN] Would have deleted $total_to_delete versions"
fi
