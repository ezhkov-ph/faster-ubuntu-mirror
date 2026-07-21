#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../run.sh
source "$PROJECT_ROOT/run.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

assert_contains() {
    local expected="$1" file="$2"
    grep -Fqx -- "$expected" "$file" || {
        printf 'Expected line was not found: %s\n' "$expected" >&2
        exit 1
    }
}

cat >"$tmp_dir/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

render_deb822 "$tmp_dir/ubuntu.sources" "$tmp_dir/ubuntu.rendered" "https://one.example/ubuntu https://two.example/ubuntu"
assert_contains "URIs: https://one.example/ubuntu https://two.example/ubuntu" "$tmp_dir/ubuntu.rendered"
[[ $(grep -c '^URIs:' "$tmp_dir/ubuntu.rendered") -eq 2 ]]
assert_contains "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg" "$tmp_dir/ubuntu.rendered"

cat >"$tmp_dir/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted
deb [arch=amd64] http://security.ubuntu.com/ubuntu noble-security main restricted
deb https://ppa.example.invalid/ubuntu noble main
EOF

render_legacy "$tmp_dir/sources.list" "$tmp_dir/sources.rendered" "https://mirror.example/ubuntu"
assert_contains "deb https://mirror.example/ubuntu noble main restricted" "$tmp_dir/sources.rendered"
assert_contains "deb [arch=amd64] https://mirror.example/ubuntu noble-security main restricted" "$tmp_dir/sources.rendered"
assert_contains "deb https://ppa.example.invalid/ubuntu noble main" "$tmp_dir/sources.rendered"

printf 'transform tests: OK\n'
