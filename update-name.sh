#!/bin/bash

NEW_NAME=$1

FILTERED_NAME=$(echo "${NEW_NAME}" | sed -e "s/[a-z0-9-]//g")

echo "New name = ${NEW_NAME}"

if [[ ${#FILTERED_NAME} != 0 ]]; then
    echo "Name only allows [a-z0-9-], found ${FILTERED_NAME} (length = ${#FILTERED_NAME})"
    exit 1
fi

NEW_NAME_WITH_UNDERSCORE=$(echo "${NEW_NAME}" | sed -e "s/-/_/g")

echo "New name with underscore = ${NEW_NAME_WITH_UNDERSCORE}"

PART_NAME="rust-"
OLD_NAME="${PART_NAME}seed"
OLD_NAME_WITH_UNDERSCORE=$(echo "${OLD_NAME}" | sed -e "s/-/_/g")

echo ${OLD_NAME_WITH_UNDERSCORE}

rg --hidden --glob '!.git/*' --files-with-matches ${OLD_NAME} | xargs -i sed -i "s/${OLD_NAME}/${NEW_NAME}/g" {}
rg --hidden --glob '!.git/*' --files-with-matches ${OLD_NAME_WITH_UNDERSCORE}
rg --hidden --glob '!.git/*' --files-with-matches ${OLD_NAME_WITH_UNDERSCORE} | xargs -i sed -i "s/${OLD_NAME_WITH_UNDERSCORE}/${NEW_NAME_WITH_UNDERSCORE}/g" {}
