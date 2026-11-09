#!/bin/bash
# cask 틀 packaging/homebrew/procwatch.rb 의 자리 표시자 @VERSION@·@SHA256@ 를 채워
# 출력 경로에 쓴다. CI 의 문법 검사와 릴리스의 탭 갱신이 같은 렌더러를 거친다.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <sha256> <output path>" >&2
    exit 2
fi
version="$1"
sha256="$2"
output="$3"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must be <major>.<minor>.<patch>: $version" >&2
    exit 2
fi
if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "sha256 must be 64 lowercase hex digits: $sha256" >&2
    exit 2
fi

# 출력 경로는 호출한 위치 기준이므로 레포 최상위로 옮기기 전에 절대 경로로 만든다.
[[ "$output" == /* ]] || output="$PWD/$output"
template="$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/packaging/homebrew/procwatch.rb"

rendered="$(<"$template")"
rendered="${rendered//@VERSION@/$version}"
rendered="${rendered//@SHA256@/$sha256}"
printf '%s\n' "$rendered" > "$output"
