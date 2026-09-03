#!/usr/bin/env bash
#
# psx-playlist.sh
#
# Version: 1.0.1
#
# v1.0.1:
#   - Changed shebang from #!/bin/zsh to #!/usr/bin/env bash for
#     consistency with the rest of the repository.
#   - Replaced zsh glob qualifiers *(/) and *(N), ${dir:t} modifier,
#     and print -r with bash equivalents.
#
set -eu

cd "psx" || exit 1

for dir in multi-disc/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"

    {
        shopt -s nullglob
        for file in "$dir"/*.chd; do
            printf '%s\n' "$file"
        done
        shopt -u nullglob
    } > "${name}.m3u"
done
