#!/bin/bash

set -euo pipefail

GIT_COMMIT=097c04d9413c59a58b00d4d1c8d5dc0ac158ffaa

dep_path=$(dirname "${0}")
dep_path=$(realpath "${dep_path}")
pushd "${dep_path}"
source ../common.sh

rm -rf arch/ *.c
git_clone_rev https://github.com/capstone-engine/capstone.git $GIT_COMMIT _upstream
mv _upstream/{arch,include,*.c,*.h} .
rm -rf _upstream

