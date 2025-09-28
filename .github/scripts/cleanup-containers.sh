#!/bin/bash

# Configuration
ORG=""
USER=""
PACKAGE_NAME="package"
PER_PAGE=100
DRY_RUN=false
SKIP_CONFIRMATION=false
CLEANUP_PR_IMAGES=true
PR_IMAGE_AGE_DAYS=30

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
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --skip-pr-cleanup)
            CLEANUP_PR_IMAGES=false
            shift
            ;;
        --pr-age-days)
            PR_IMAGE_AGE_DAYS="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--org ORG | --user USER] [--package PACKAGE_NAME] [--dry-run] [--yes] [--skip-pr-cleanup] [--pr-age-days DAYS] [--help]"
            echo "  --org              GitHub organization name"
            echo "  --user             GitHub username"
            echo "  --package          Package name (default: $PACKAGE_NAME)"
            echo "  --dry-run          Show what would be deleted without actually deleting"
            echo "  --yes              Skip confirmation prompt"
            echo "  --skip-pr-cleanup  Skip cleanup of old PR images"
            echo "  --pr-age-days      Age in days for PR images to be considered old (default: $PR_IMAGE_AGE_DAYS)"
            echo "  --help             Show this help message"
            echo ""
            echo "Note: --org and --user are mutually exclusive. One must be specified."
            echo "Note: Images with the 'edge' or 'latest' tag will never be deleted."
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

# Function to check if a date is older than specified days
is_older_than_days() {
    local date_str="$1"
    local days="$2"

    # Convert date to epoch timestamp
    local date_epoch=$(date -d "$date_str" +%s 2> /dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Warning: Could not parse date: $date_str" >&2
        return 1
    fi

    # Calculate cutoff timestamp (current time - days in seconds)
    local cutoff_epoch=$(($(date +%s) - (days * 24 * 60 * 60)))

    # Return 0 (true) if date is older than cutoff
    [[ $date_epoch -lt $cutoff_epoch ]]
}

# Function to check if tags contain pr-*-latest pattern
has_pr_latest_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq -e '.[] | select(test("^pr-.*-latest$"))' > /dev/null
}

# Function to check if tags contain pr-sha patterns
has_pr_sha_tag() {
    local tags_json="$1"
    # Match pr-{sha}-{sha} or pr-{sha}-{sha}-{architecture}
    # SHA pattern: 40 character hex string (git SHA-1)
    echo "$tags_json" | jq -e '.[] | select(test("^pr-[a-f0-9]{40}-[a-f0-9]{40}(-[a-zA-Z0-9_-]+)?$"))' > /dev/null
}

# Function to check if tags contain the "edge" tag
has_edge_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq -e '.[] | select(. == "edge")' > /dev/null
}

# Function to check if tags contain the "latest" tag
has_latest_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq -e '.[] | select(. == "latest")' > /dev/null
}

# Function to check if tags contain attestation pattern (sha256-{sha256})
has_attestation_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq -e '.[] | select(test("^sha256-[a-f0-9]{64}$"))' > /dev/null
}

# Function to extract SHA256 from attestation tag
extract_sha256_from_attestation() {
    local tags_json="$1"
    echo "$tags_json" | jq -r '.[] | select(test("^sha256-[a-f0-9]{64}$")) | sub("^sha256-"; "")'
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

# ========== FIRST PASS: Collect images to delete ==========

# Collect all version IDs to delete
untagged_versions=()
old_pr_versions=()
old_pr_descriptions=()
old_pr_sha_versions=()
old_pr_sha_descriptions=()
protected_versions=0
page=1

echo "Fetching version data..."

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

            # Skip any version with "edge" or "latest" tag - they're protected
            if has_edge_tag "$tags" || has_latest_tag "$tags"; then
                ((protected_versions++))
                continue
            fi

            # Check for untagged versions
            if echo "$tags" | jq -e '. == []' > /dev/null; then
                untagged_versions+=("$version_id")
            fi

            # Check for old PR images if cleanup is enabled
            if [[ "$CLEANUP_PR_IMAGES" == "true" ]] && is_older_than_days "$created_at" "$PR_IMAGE_AGE_DAYS"; then
                tags_str=$(echo "$tags" | jq --raw-output '.[]' | tr '\n' ',' | sed 's/,$//')

                # Check for pr-*-latest pattern
                if has_pr_latest_tag "$tags"; then
                    old_pr_versions+=("$version_id")
                    old_pr_descriptions+=("old PR latest image: $created_at [$tags_str]")
                # Check for pr-sha-sha(-arch) pattern
                elif has_pr_sha_tag "$tags"; then
                    old_pr_sha_versions+=("$version_id")
                    old_pr_sha_descriptions+=("old PR SHA image: $created_at [$tags_str]")
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
echo "Found ${#old_pr_versions[@]} old PR latest images (older than $PR_IMAGE_AGE_DAYS days)"
echo "Found ${#old_pr_sha_versions[@]} old PR SHA images (older than $PR_IMAGE_AGE_DAYS days)"
echo "Protected $protected_versions versions with 'edge' or 'latest' tag"

total_to_delete=$((${#untagged_versions[@]} + ${#old_pr_versions[@]} + ${#old_pr_sha_versions[@]}))

if [[ $total_to_delete -eq 0 ]]; then
    echo "No versions found to delete."
fi

# Show what we found
if [[ ${#untagged_versions[@]} -gt 0 ]]; then
    echo ""
    echo "Untagged version IDs:"
    printf '%s\n' "${untagged_versions[@]}"
fi

if [[ ${#old_pr_versions[@]} -gt 0 ]]; then
    echo ""
    echo "Old PR latest image versions:"
    for i in "${!old_pr_versions[@]}"; do
        echo "${old_pr_versions[$i]}: ${old_pr_descriptions[$i]}"
    done
fi

if [[ ${#old_pr_sha_versions[@]} -gt 0 ]]; then
    echo ""
    echo "Old PR SHA image versions:"
    for i in "${!old_pr_sha_versions[@]}"; do
        echo "${old_pr_sha_versions[$i]}: ${old_pr_sha_descriptions[$i]}"
    done
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

    # Delete old PR latest versions
    if [[ ${#old_pr_versions[@]} -gt 0 ]]; then
        echo "Cleaning up old PR latest images..."
        for i in "${!old_pr_versions[@]}"; do
            delete_version "${old_pr_versions[$i]}" "${old_pr_descriptions[$i]}"

            if [[ "$DRY_RUN" == "false" ]]; then
                if [[ $? -eq 0 ]]; then
                    ((deleted_count++))
                else
                    ((failed_count++))
                fi
            fi
        done
    fi

    # Delete old PR SHA versions
    if [[ ${#old_pr_sha_versions[@]} -gt 0 ]]; then
        echo "Cleaning up old PR SHA images..."
        for i in "${!old_pr_sha_versions[@]}"; do
            delete_version "${old_pr_sha_versions[$i]}" "${old_pr_sha_descriptions[$i]}"

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

# ========== SECOND PASS: Find and clean up orphaned attestations ==========

echo ""
echo "=== SECOND PASS: ATTESTATION CLEANUP ==="

echo "Looking for orphaned attestations..."

# Collect all existing image SHA256s and all attestations
declare -A existing_images # sha256 -> 1
attestation_versions=()
attestation_descriptions=()
page=1

while true; do
    echo "Processing attestations page $page..."

    response=$(get_versions_page $page)

    if [[ -z "$response" ]] || echo "$response" | jq --exit-status '.message' &> /dev/null; then
        if echo "$response" | jq -e '.message' &> /dev/null; then
            echo "Error: $(echo "$response" | jq --raw-output '.message')"
            exit 1
        fi
        break
    fi

    # If no data on this page, we're done
    page_data=$(echo "$response" | jq --raw-output '.[]')
    if [[ -z "$page_data" ]]; then
        break
    fi

    # Process each version
    while IFS= read -r version; do
        if [[ -n "$version" ]]; then
            version_id=$(echo "$version" | jq --raw-output '.id')
            tags=$(echo "$version" | jq '.metadata.container.tags')
            image_name=$(echo "$version" | jq --raw-output '.name // empty')

            # If this is an attestation, store it for checking
            if has_attestation_tag "$tags"; then
                sha256=$(extract_sha256_from_attestation "$tags")
                if [[ -n "$sha256" ]]; then
                    attestation_versions+=("$version_id")
                    attestation_descriptions+=("attestation for SHA256: $sha256")
                fi
            else
                # This is a regular image, store its SHA256 if available
                if [[ -n "$image_name" ]] && [[ "$image_name" =~ ^sha256:[a-f0-9]{64}$ ]]; then
                    image_sha256="${image_name#sha256:}"
                    existing_images["$image_sha256"]=1
                fi
            fi
        fi
    done <<< "$(echo "$response" | jq -c '.[]')"

    version_count=$(echo "$response" | jq '. | length')
    if [[ $version_count -lt $PER_PAGE ]]; then
        break
    fi

    ((page++))
done

# Find orphaned attestations
orphaned_attestations=()
orphaned_descriptions=()

for i in "${!attestation_versions[@]}"; do
    version_id="${attestation_versions[$i]}"
    description="${attestation_descriptions[$i]}"

    # Extract SHA256 from description
    sha256=$(echo "$description" | sed 's/.*SHA256: //')

    # Check if corresponding image exists
    if [[ -z "${existing_images[$sha256]:-}" ]]; then
        orphaned_attestations+=("$version_id")
        orphaned_descriptions+=("orphaned $description")
    fi
done

if [[ ${#orphaned_attestations[@]} -eq 0 ]]; then
    echo "No orphaned attestations found."
else
    echo "Found ${#orphaned_attestations[@]} orphaned attestations"

    # Show orphaned attestations
    echo ""
    echo "Orphaned attestations:"
    for i in "${!orphaned_attestations[@]}"; do
        echo "${orphaned_attestations[$i]}: ${orphaned_descriptions[$i]}"
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "[DRY RUN MODE] The following ${#orphaned_attestations[@]} orphaned attestations would be deleted."
    fi

    # Confirm attestation deletion (unless dry run or --yes flag)
    attestation_deletion_cancelled=false
    if [[ "$DRY_RUN" == "false" && "$SKIP_CONFIRMATION" == "false" ]]; then
        echo ""
        read -p "Are you sure you want to delete ${#orphaned_attestations[@]} orphaned attestations? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Attestation cleanup cancelled."
            attestation_deletion_cancelled=true
        fi
    fi

    # Delete orphaned attestations (if not cancelled and not dry run)
    if [[ "$attestation_deletion_cancelled" == "false" && "$DRY_RUN" == "false" ]]; then
        echo ""
        echo "Cleaning up orphaned attestations..."
        for i in "${!orphaned_attestations[@]}"; do
            delete_version "${orphaned_attestations[$i]}" "${orphaned_descriptions[$i]}"

            if [[ $? -eq 0 ]]; then
                ((deleted_count++))
            else
                ((failed_count++))
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
    total_would_delete=$((total_to_delete + ${#orphaned_attestations[@]}))
    echo "[DRY RUN] Would have deleted $total_would_delete versions total"
fi
