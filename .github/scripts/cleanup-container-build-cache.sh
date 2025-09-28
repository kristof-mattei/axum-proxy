#!/bin/bash

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
                echo "Error: --org and --user are mutually exclusive"
                exit 1
            fi
            ORG="$2"
            shift 2
            ;;
        --user)
            if [[ -n "$ORG" ]]; then
                echo "Error: --org and --user are mutually exclusive"
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
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate that either --org or --user is specified
if [[ -z "$ORG" && -z "$USER" ]]; then
    echo "Error: Either --org or --user must be specified"
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

echo "Querying container versions for $TARGET_TYPE $TARGET, package $PACKAGE_NAME..."

# Function to get versions for a specific page
get_versions_page() {
    local page=$1

    gh api \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        "$API_PATH/packages/container/$PACKAGE_NAME/versions?per_page=$PER_PAGE&page=$page"
}

# Function to delete a version
delete_version() {
    local version_id=$1
    local description="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would delete version ID: $version_id ($description)"
    else
        echo "Deleting version ID: $version_id ($description)"
        gh api \
            --method DELETE \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            "$API_PATH/packages/container/$PACKAGE_NAME/versions/$version_id"

        if [[ $? -eq 0 ]]; then
            echo "Successfully deleted version ID: $version_id"
        else
            echo "Failed to delete version ID: $version_id"
        fi
    fi
}

# Function to check if a date is older than threshold
is_older_than_threshold() {
    local date_str=$1
    local threshold_seconds=$((DAYS_THRESHOLD * 24 * 60 * 60))
    local current_timestamp=$(date +%s)
    local version_timestamp=$(date -d "$date_str" +%s 2> /dev/null)

    if [[ -z "$version_timestamp" ]]; then
        echo "Warning: Could not parse date: $date_str" >&2
        return 1
    fi

    local age_seconds=$((current_timestamp - version_timestamp))
    [[ $age_seconds -gt $threshold_seconds ]]
}

# Check if gh CLI is installed and authenticated
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "Error: Not authenticated with GitHub CLI. Run 'gh auth login' first."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed"
    exit 1
fi

# Collect all version IDs to delete
untagged_versions=()
old_tagged_versions=()
page=1

echo "Fetching version data..."
echo "Will delete tagged versions older than $DAYS_THRESHOLD days..."

while true; do
    echo "Processing page $page..."

    response=$(get_versions_page $page)

    if [[ -z "$response" ]] || echo "$response" | jq --exit-status '.message' &> /dev/null; then
        if echo "$response" | jq -e '.message' &> /dev/null; then
            echo "Error: $(echo "$response" | jq --raw-output '.message')"
            exit 1
        fi
        break
    fi

    # Extract version data
    page_data=$(echo "$response" | jq --raw-output '.[]')

    # If no data on this page, we're done
    if [[ -z "$page_data" ]]; then
        break
    fi

    # Process each version individually
    while IFS= read -r version; do
        if [[ -n "$version" ]]; then
            version_id=$(echo "$version" | jq --raw-output '.id')
            tags=$(echo "$version" | jq '.metadata.container.tags')
            created_at=$(echo "$version" | jq --raw-output '.created_at')
            updated_at=$(echo "$version" | jq --raw-output '.updated_at')

            # Check for untagged versions
            if echo "$tags" | jq -e '. == []' > /dev/null; then
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
                        old_tagged_versions+=("$version_id:$tag_list:$check_date")
                    fi
                fi
            fi
        fi
    done <<< "$(echo "$response" | jq -c '.[]')"

    # Check if we got a full page (if less than PER_PAGE, we're done)
    version_count=$(echo "$response" | jq '. | length')
    if [[ $version_count -lt $PER_PAGE ]]; then
        break
    fi

    ((page++))
done

# Summary
echo ""
echo "=== CLEANUP SUMMARY ==="
echo "Found ${#untagged_versions[@]} untagged versions"
echo "Found ${#old_tagged_versions[@]} tagged versions older than $DAYS_THRESHOLD days"

total_to_delete=$((${#untagged_versions[@]} + ${#old_tagged_versions[@]}))

if [[ $total_to_delete -eq 0 ]]; then
    echo "No versions found to delete."
fi

# Show what we found
if [[ ${#untagged_versions[@]} -gt 0 ]]; then
    echo ""
    echo "Untagged version IDs:"
    printf '%s\n' "${untagged_versions[@]}"
fi

if [[ ${#old_tagged_versions[@]} -gt 0 ]]; then
    echo ""
    echo "Old tagged versions (ID:tags:date):"
    printf '%s\n' "${old_tagged_versions[@]}"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[DRY RUN MODE] The following $total_to_delete versions would be deleted."
fi

# Initialize skip flag
skip_image_deletion=false

# Confirm deletion (unless dry run or --yes flag)
if [[ "$DRY_RUN" == "false" && "$SKIP_CONFIRMATION" == "false" && $total_to_delete -gt 0 ]]; then
    echo ""
    read -p "Are you sure you want to delete $total_to_delete versions? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Image deletion cancelled."
        skip_image_deletion=true
    fi
fi

# Delete versions (only if not skipped)
deleted_count=0
failed_count=0

if [[ "$skip_image_deletion" == "false" && $total_to_delete -gt 0 ]]; then
    echo ""
    echo "=== STARTING CLEANUP ==="

    # Delete untagged versions
    if [[ ${#untagged_versions[@]} -gt 0 ]]; then
        echo "Cleaning up untagged versions..."
        for version_id in "${untagged_versions[@]}"; do
            delete_version "$version_id" "untagged"

            if [[ "$DRY_RUN" == "false" ]]; then
                if [[ $? -eq 0 ]]; then
                    ((deleted_count++))
                else
                    ((failed_count++))
                fi
            fi
        done
    fi

    # Delete old tagged versions
    if [[ ${#old_tagged_versions[@]} -gt 0 ]]; then
        echo "Cleaning up old tagged versions..."
        for version_info in "${old_tagged_versions[@]}"; do
            IFS=':' read -r version_id tags date <<< "$version_info"
            delete_version "$version_id" "tagged: $tags (from $date)"

            if [[ "$DRY_RUN" == "false" ]]; then
                if [[ $? -eq 0 ]]; then
                    ((deleted_count++))
                else
                    ((failed_count++))
                fi
            fi
        done
    fi
fi

# Final summary
echo ""
echo "=== CLEANUP COMPLETE ==="
if [[ "$DRY_RUN" == "false" ]]; then
    echo "Successfully deleted: $deleted_count versions"
    if [[ $failed_count -gt 0 ]]; then
        echo "Failed to delete: $failed_count versions"
    fi
else
    total_would_delete=$((total_to_delete))
    echo "[DRY RUN] Would have deleted $total_would_delete versions total"
fi
