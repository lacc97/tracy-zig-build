git_clone_rev() {
    repo=$1
    rev=$2
    dir=$3

    rm -rf "$dir"
    mkdir "$dir"
    pushd "$dir"
    git init -q
    git fetch "$repo" "$rev" --depth 1
    git checkout -q FETCH_HEAD
    popd
}
