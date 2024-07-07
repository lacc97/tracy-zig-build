#!/bin/bash

set -euo pipefail

GIT_COMMIT=6d1deb5640ed11da01995fb1791115cfebe54dbf

dep_path=$(dirname "${0}")
dep_path=$(realpath "${dep_path}")
pushd "${dep_path}"
source lib/common.sh

rm -rf upstream
mkdir upstream
git_clone_rev https://github.com/wolfpld/tracy.git $GIT_COMMIT _upstream
mv _upstream/{capture,dtl,imgui,nfd,profiler,public,server,zstd} upstream
find upstream '!' '(' -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.m' ')' -type f -delete
rm -rf _upstream

