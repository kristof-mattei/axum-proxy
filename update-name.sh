#!/bin/bash

new_name=$1

filtered_name=$(echo "${new_name}" | sed -e "s/[a-z0-9-]//g")

echo "New name = ${new_name}"

if [[ ${#filtered_name} != 0 ]]; then
    echo "Name only allows [a-z0-9-], found ${filtered_name} (length = ${#filtered_name})"
    exit 1
fi

new_name_with_underscore=$(echo "${new_name}" | sed -e "s/-/_/g")

echo "New name with underscore = ${new_name_with_underscore}"

part_name="rust-"
old_name="${part_name}seed"
old_name_with_underscore=$(echo "${old_name}" | sed -e "s/-/_/g")

echo ${old_name_with_underscore}

rg --hidden --glob '!.git/*' --files-with-matches ${old_name} | xargs -i sed -i "s/${old_name}/${new_name}/g" {}
rg --hidden --glob '!.git/*' --files-with-matches ${old_name_with_underscore}
rg --hidden --glob '!.git/*' --files-with-matches ${old_name_with_underscore} | xargs -i sed -i "s/${old_name_with_underscore}/${new_name_with_underscore}/g" {}
