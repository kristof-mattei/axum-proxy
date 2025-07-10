#!/bin/bash

# fetch so we can merge in without first
# having to checkout & pull the branches
git fetch origin
git fetch upstream

# delete existing branch
git branch -D update-from-upstream

# delete remote update-from-upstream
git push origin :update-from-upstream

# we create a new branch from the origin's main (=HEAD, because we fetched)
git checkout -b update-from-upstream origin/main

git push --set-upstream origin update-from-upstream

# merge in the changes from upstream
git merge upstream/main --no-edit

# fix stuff and ...
# git push
