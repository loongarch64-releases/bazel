#!/bin/bash
set -eou pipefail

UPSTREAM_OWNER=bazelbuild
UPSTREAM_REPO=bazel

curl -s https://api.github.com/repos/"$UPSTREAM_OWNER"/"$UPSTREAM_REPO"/releases/latest \
     | jq -r ".tag_name"
