#!/bin/zsh

cd "psx" || exit 1

for dir in multi-disc/*(/); do
    name="${dir:t}"

    {
        for file in "$dir"/*.chd(N); do
            print -r -- "$file"
        done
    } > "${name}.m3u"
done
