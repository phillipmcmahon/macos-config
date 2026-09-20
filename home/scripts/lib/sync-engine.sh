#!/usr/bin/env bash
#
# Script: sync-engine.sh
# Purpose: Checked Bash inventory, transaction planning and file deployment.
# Version: 1.0.0
# Requires: Bash 5+, Git, jq and common.sh. Internal interface only.
# Documentation: docs/USER-MANUAL.md
#

set -Eeuo pipefail
umask 077
ENGINE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$ENGINE_DIR/common.sh"

# Configuration and command interface
(($# >= 6)) || die 'Incomplete internal engine request.'
ACTION=$1 ENGINE_HOME=$2 REPO=$3 MACHINE=$4 AUTO=$5 VALUE=$6
shift 6
SHARED_FILES=() SHARED_DIRS=() MACHINE_FILES=() MACHINE_DIRS=() EXPLICIT_DIRS=() EXCLUDES=()
array=''
while (($#)); do
    case $1 in
        --shared-files) array=SHARED_FILES ;; --shared-dirs) array=SHARED_DIRS ;;
        --machine-files) array=MACHINE_FILES ;; --machine-dirs) array=MACHINE_DIRS ;;
        --explicit-dirs) array=EXPLICIT_DIRS ;; --excludes) array=EXCLUDES ;;
        *)
            [[ -n $array ]] || die 'Unknown internal engine argument.'
            declare -n dest_array=$array
            dest_array+=("$1")
            unset -n dest_array
            ;;
    esac
    shift
done
STATE="$REPO/.git/macos-config-sync-v31-$MACHINE"
MANIFEST="$STATE/pending.json"
REGISTRY="$STATE/ownership.json"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/config-engine.XXXXXXXX")
PUBLISH_TEMP=''
cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z $PUBLISH_TEMP ]] || rm -f -- "$PUBLISH_TEMP" || rc=1
    rm -rf -- "$TEMP" || rc=1
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Path and JSON helpers
valid() {
    [[ $1 != *\\* ]] || die "Backslashes are unsupported in managed paths."
    [[ -n $1 && $1 != /* && $1 != */ && $1 != *[[:cntrl:]]* && /$1/ != */../* && /$1/ != */./* && /$1/ != */.git/* && $1 != *'//'* ]] || die "Unsupported managed path: $1"
}
safe() {
    valid "$2"
    reject_symlinks "$1/$2" || exit 1
}
mapping() {
    local name=$1 entry
    valid "$name"
    for entry in "${SHARED_FILES[@]}"; do [[ $name != "$entry" ]] || {
        printf 'home/%s\n' "$name"
        return
    }; done
    for entry in "${SHARED_DIRS[@]}"; do [[ $name != "$entry/"* ]] || {
        printf 'home/%s\n' "$name"
        return
    }; done
    for entry in "${MACHINE_FILES[@]}"; do [[ $name != "$entry" ]] || {
        printf 'machines/%s/home/%s\n' "$MACHINE" "$name"
        return
    }; done
    for entry in "${MACHINE_DIRS[@]}"; do [[ $name != "$entry/"* ]] || {
        printf 'machines/%s/home/%s\n' "$MACHINE" "$name"
        return
    }; done
    return 1
}
unmap() {
    local name mapped
    case $1 in
        home/*) name=${1#home/} ;;
        machines/"$MACHINE"/home/*) name=${1#machines/"$MACHINE"/home/} ;;
        *) return 1 ;;
    esac
    mapped=$(mapping "$name") || return 1
    [[ $mapped == "$1" ]] || return 1
    printf '%s\n' "$name"
}
digest() {
    [[ -e $1 || -L $1 ]] || {
        printf 'null\n'
        return
    }
    [[ -f $1 && ! -L $1 ]] || die "Expected regular file: $1"
    sha256_of "$1" || die "Cannot hash: $1"
}
save_json() {
    local destination=$1 temporary
    mkdir -p -- "${destination%/*}"
    [[ ! -L $destination ]] || die 'Symlink state file.'
    jq -e . > "$TEMP/validated.json"
    temporary=$(mktemp "${destination%/*}/.state.XXXXXXXX")
    cp "$TEMP/validated.json" "$temporary"
    mv -f -- "$temporary" "$destination"
}
read_map() {
    local file=$1 name=$2 key value
    local -n map_ref=$name
    map_ref=()
    jq -r 'to_entries[] | [.key, (.value // "null")] | @tsv' "$file" > "$TEMP/map.tsv"
    while IFS=$'\t' read -r key value; do
        [[ -n $key ]] || continue
        valid "$key"
        map_ref["$key"]=$value
    done < "$TEMP/map.tsv"
}
write_map() {
    local name=$1 file=$2 key
    # This scalar declares a reference to the caller's associative array.
    # shellcheck disable=SC2178
    local -n map_ref=$name
    : > "$TEMP/write.tsv"
    for key in "${!map_ref[@]}"; do printf '%s\t%s\n' "$key" "${map_ref[$key]}" >> "$TEMP/write.tsv"; done
    jq -Rn '[inputs | split("\t") | {key:.[0], value:(if .[1] == "null" then null else .[1] end)}] | from_entries' < "$TEMP/write.tsv" > "$file"
}

# Ownership and scope
reject_symlinks "$STATE" || exit 1
if [[ -f $REGISTRY ]]; then
    jq -e 'type == "object" and (.add | type == "array") and (.forget | type == "array") and all(.add[]?, .forget[]?; type == "string")' "$REGISTRY" > /dev/null
    cp "$REGISTRY" "$TEMP/ownership.json"
else printf '{"add":[],"forget":[]}\n' > "$TEMP/ownership.json"; fi
declare -A FORGOTTEN=() ENROLLED=()
jq -r '.forget[]' "$TEMP/ownership.json" > "$TEMP/forget"
while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    valid "$entry"
    FORGOTTEN["$entry"]=1
done < "$TEMP/forget"
jq -r '.add[]' "$TEMP/ownership.json" > "$TEMP/add"
while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    valid "$entry"
    ENROLLED["$entry"]=1
done < "$TEMP/add"
excluded() {
    local name=$1 pattern part i
    local -a parts=()
    [[ ! ${FORGOTTEN[$name]+x} ]] || return 0
    IFS=/ read -r -a parts <<< "$name"
    for part in "${parts[@]}"; do [[ $part != .git ]] || return 0; done
    for pattern in "${EXCLUDES[@]}"; do
        if [[ $pattern == */ ]]; then
            # Exclusions intentionally interpret the configured value as a glob.
            # shellcheck disable=SC2053
            for ((i = 0; i < ${#parts[@]} - 1; i++)); do [[ ${parts[i]} != ${pattern%/} ]] || return 0; done
        else
            # shellcheck disable=SC2053
            for part in "${parts[@]}"; do [[ $part != $pattern ]] || return 0; done
        fi
    done
    return 1
}
# Reject overlapping scopes instead of silently assigning the same path twice.
scopes=("${SHARED_FILES[@]}" "${SHARED_DIRS[@]}" "${MACHINE_FILES[@]}" "${MACHINE_DIRS[@]}")
for ((i = 0; i < ${#scopes[@]}; i++)); do
    valid "${scopes[i]}"
    for ((j = 0; j < i; j++)); do
        [[ ${scopes[i]} != "${scopes[j]}" && ${scopes[i]} != "${scopes[j]}/"* && ${scopes[j]} != "${scopes[i]}/"* ]] || die 'Managed scopes overlap. Use non-overlapping file and directory entries.'
    done
done
# A stable JSON config fingerprint prevents resuming with different settings.
{
    printf '%s\0' "$ENGINE_HOME" "$REPO" "$MACHINE" "$AUTO"
    for array in SHARED_FILES SHARED_DIRS MACHINE_FILES MACHINE_DIRS EXPLICIT_DIRS EXCLUDES; do
        printf '%s\0' "$array"
        declare -n values=$array
        printf '%s\0' "${values[@]}"
        unset -n values
    done
    jq -Sc . "$TEMP/ownership.json"
} > "$TEMP/config"
CONFIG_DIGEST=$(sha256_of "$TEMP/config")

# Inventories and transaction validation
inventory() {
    local output=$1 entry path name hash
    declare -A items=()
    for name in "${SHARED_FILES[@]}" "${MACHINE_FILES[@]}"; do
        if excluded "$name"; then continue; fi
        safe "$ENGINE_HOME" "$name"
        if [[ -e $ENGINE_HOME/$name ]]; then items["$name"]=$(digest "$ENGINE_HOME/$name"); fi
    done
    for entry in "${SHARED_DIRS[@]}" "${MACHINE_DIRS[@]}"; do
        safe "$ENGINE_HOME" "$entry"
        [[ -e $ENGINE_HOME/$entry ]] || continue
        [[ -d $ENGINE_HOME/$entry ]] || die "Expected directory: $entry"
        find "$ENGINE_HOME/$entry" -mindepth 1 -print0 > "$TEMP/find"
        while IFS= read -r -d '' path; do
            name=${path#"$ENGINE_HOME/"}
            # Check exclusions before symlink rejection, including directory names.
            if excluded "$name" || { [[ -d $path ]] && excluded "$name/placeholder"; }; then continue; fi
            safe "$ENGINE_HOME" "$name"
            [[ ! -d $path ]] || continue
            hash=$(digest "$path")
            items["$name"]=$hash
        done < "$TEMP/find"
    done
    write_map items "$output"
}
tracked() {
    local commit=$1 output=$2 entry metadata path mode kind _oid name
    declare -A items=()
    git -C "$REPO" ls-tree -rz --full-tree "$commit" > "$TEMP/tree"
    while IFS= read -r -d '' entry; do
        metadata=${entry%%$'\t'*} path=${entry#*$'\t'}
        if ! name=$(unmap "$path"); then continue; fi
        if excluded "$name"; then continue; fi
        IFS=' ' read -r mode kind _oid <<< "$metadata"
        [[ $kind == blob && ($mode == 100644 || $mode == 100755) ]] || die "Unsupported Git file: $path"
        # Consumed by write_map through its nameref argument.
        # shellcheck disable=SC2034
        items["$name"]=$path
    done < "$TEMP/tree"
    write_map items "$output"
}
load_manifest() {
    [[ -f $MANIFEST && ! -L $MANIFEST ]] || die 'Missing pending transaction.'
    jq -e --arg config "$CONFIG_DIGEST" '.engine == "bash-1" and .config == $config' "$MANIFEST" > /dev/null || die 'Pending transaction belongs to the earlier engine or different configuration. Finish it using the original bundle and settings first.'
}
check_home() {
    local phase name actual original wanted
    declare -A current=() captured=() desired=() all=()
    inventory "$TEMP/current.json"
    read_map "$TEMP/current.json" current
    jq '.home' "$MANIFEST" > "$TEMP/captured.json"
    jq '.desired' "$MANIFEST" > "$TEMP/desired.json"
    read_map "$TEMP/captured.json" captured
    read_map "$TEMP/desired.json" desired
    phase=$(jq -r '.phase' "$MANIFEST")
    for name in "${!current[@]}" "${!captured[@]}" "${!desired[@]}"; do all["$name"]=1; done
    for name in "${!all[@]}"; do
        actual=${current[$name]:-null} original=${captured[$name]:-null} wanted=${desired[$name]:-null}
        if [[ $phase == deployed && ${desired[$name]+x} ]]; then
            [[ $actual == "$wanted" ]] || die "HOME changed after deployment: $name"
        elif [[ $phase == deploying && ${desired[$name]+x} ]]; then
            [[ $actual == "$original" || $actual == "$wanted" ]] || die "HOME changed during deployment: $name"
        else [[ $actual == "$original" ]] || die "HOME changed after capture: $name"; fi
    done
}

# Operations
case $ACTION in
    add | forget)
        [[ ! -f $MANIFEST ]] || die 'Finish the pending sync before changing ownership.'
        valid "$VALUE"
        mapping "$VALUE" > /dev/null || die 'File is outside configured scopes.'
        safe "$ENGINE_HOME" "$VALUE"
        if [[ $ACTION == add ]]; then
            unset 'FORGOTTEN[$VALUE]'
            if excluded "$VALUE"; then die 'File matches an exclusion.'; fi
            [[ -f $ENGINE_HOME/$VALUE ]] || die 'Add requires an existing regular file.'
            jq --arg p "$VALUE" '.forget -= [$p] | .add = ((.add + [$p]) | unique)' "$TEMP/ownership.json" | save_json "$REGISTRY"
        else jq --arg p "$VALUE" '.add -= [$p] | .forget = ((.forget + [$p]) | unique)' "$TEMP/ownership.json" | save_json "$REGISTRY"; fi
        printf '%s: %s (effective on next sync)\n' "${ACTION^^}" "$VALUE"
        ;;
    snapshot)
        [[ ! -f $MANIFEST ]] || die 'A transaction is already pending.'
        inventory "$TEMP/home.json"
        jq -n --arg base "$VALUE" --arg config "$CONFIG_DIGEST" --slurpfile home "$TEMP/home.json" '{engine:"bash-1", base:$base, home:$home[0], config:$config, phase:"captured", desired:{}}' | save_json "$MANIFEST"
        ;;
    collect)
        load_manifest
        check_home
        base=$(jq -r '.base' "$MANIFEST")
        tracked "$base" "$TEMP/known.json"
        declare -A known=() captured=() selected=()
        read_map "$TEMP/known.json" known
        jq '.home' "$MANIFEST" > "$TEMP/captured.json"
        read_map "$TEMP/captured.json" captured
        for name in "${!known[@]}" "${SHARED_FILES[@]}" "${MACHINE_FILES[@]}" "${!ENROLLED[@]}"; do
            if mapping "$name" > /dev/null; then selected["$name"]=1; fi
        done
        if [[ $AUTO == 1 ]]; then
            for name in "${!captured[@]}"; do
                manual=0
                for entry in "${EXPLICIT_DIRS[@]}"; do [[ $name != "$entry/"* ]] || manual=1; done
                ((manual)) || selected["$name"]=1
            done
        fi
        for name in "${!selected[@]}"; do
            if excluded "$name"; then continue; fi
            mapped=$(mapping "$name")
            safe "$REPO" "$mapped"
            safe "$ENGINE_HOME" "$name"
            source=$ENGINE_HOME/$name destination=$REPO/$mapped
            for entry in "${MACHINE_FILES[@]}"; do
                if [[ $name == "$entry" && -f $STATE/generated/$name ]]; then
                    safe "$STATE" "generated/$name"
                    source=$STATE/generated/$name
                fi
            done
            if [[ -e $source ]]; then
                if [[ $(digest "$source") != "$(digest "$destination")" ]]; then
                    mkdir -p "${destination%/*}"
                    cp -p -- "$source" "$destination"
                fi
            elif [[ -e $destination ]]; then
                [[ -f $destination ]] || die 'Refusing directory removal.'
                rm -- "$destination"
            fi
        done
        for name in "${!FORGOTTEN[@]}"; do
            if ! mapped=$(mapping "$name"); then continue; fi
            safe "$REPO" "$mapped"
            if [[ -e $REPO/$mapped ]]; then
                [[ -f $REPO/$mapped ]] || die 'Forget requires a file.'
                rm -- "$REPO/$mapped"
            fi
        done
        check_home
        ;;
    check)
        load_manifest
        check_home
        ;;
    plan)
        load_manifest
        check_home
        phase=$(jq -r '.phase' "$MANIFEST")
        target=$(git -C "$REPO" rev-parse HEAD)
        if [[ $phase == deploying || $phase == deployed ]]; then
            [[ $(jq -r '.target' "$MANIFEST") == "$target" ]] || die 'Target changed during deployment.'
        else
            base=$(jq -r '.base' "$MANIFEST") local_commit=$(jq -r '.local // .base' "$MANIFEST")
            tracked "$target" "$TEMP/files.json"
            tracked "$base" "$TEMP/basefiles.json"
            tracked "$local_commit" "$TEMP/localfiles.json"
            jq '.home' "$MANIFEST" > "$TEMP/home.json"
            declare -A files=() basefiles=() localfiles=() homefiles=() desired=() all=()
            read_map "$TEMP/files.json" files
            read_map "$TEMP/basefiles.json" basefiles
            read_map "$TEMP/localfiles.json" localfiles
            read_map "$TEMP/home.json" homefiles
            for name in "${!files[@]}" "${!basefiles[@]}"; do all["$name"]=1; done
            for name in "${!all[@]}"; do
                wanted=null
                if [[ ${files[$name]+x} ]]; then
                    safe "$REPO" "${files[$name]}"
                    wanted=$(digest "$REPO/${files[$name]}")
                    [[ $wanted != null ]] || die 'Missing deployment source.'
                fi
                if [[ ! ${localfiles[$name]+x} && ${homefiles[$name]+x} && ${homefiles[$name]} != "$wanted" ]]; then die "Remote addition conflicts with local-only file: $name"; fi
                desired["$name"]=$wanted
            done
            write_map desired "$TEMP/desired.json"
            jq --arg target "$target" --slurpfile desired "$TEMP/desired.json" '.target=$target | .desired=$desired[0]' "$MANIFEST" | save_json "$MANIFEST"
        fi
        ;;
    local)
        load_manifest
        commit=$(git -C "$REPO" rev-parse HEAD)
        git -C "$REPO" update-ref "refs/macos-config-sync/$MACHINE/pending-local" "$commit"
        jq --arg commit "$commit" '.local=$commit' "$MANIFEST" | save_json "$MANIFEST"
        ;;
    deploy)
        load_manifest
        check_home
        [[ $(jq -r '.target' "$MANIFEST") == "$(git -C "$REPO" rev-parse HEAD)" ]] || die 'Target changed.'
        jq '.phase="deploying"' "$MANIFEST" | save_json "$MANIFEST"
        jq '.home' "$MANIFEST" > "$TEMP/home.json"
        jq '.desired' "$MANIFEST" > "$TEMP/desired.json"
        declare -A homefiles=() desired=()
        read_map "$TEMP/home.json" homefiles
        read_map "$TEMP/desired.json" desired
        for name in "${!desired[@]}"; do
            safe "$ENGINE_HOME" "$name"
            destination=$ENGINE_HOME/$name wanted=${desired[$name]}
            actual=$(digest "$destination")
            [[ $actual != "$wanted" ]] || continue
            [[ $actual == "${homefiles[$name]:-null}" ]] || die "Concurrent HOME edit: $name"
            if [[ $wanted == null ]]; then
                rm -- "$destination"
                printf 'DELETED (backed up): %s\n' "$name"
            else
                mapped=$(mapping "$name")
                safe "$REPO" "$mapped"
                source=$REPO/$mapped
                [[ $(digest "$source") == "$wanted" ]] || die "Deployment source changed: $name"
                mkdir -p -- "${destination%/*}"
                PUBLISH_TEMP=$(mktemp "${destination%/*}/.config-sync.XXXXXXXX")
                cp -p -- "$source" "$PUBLISH_TEMP"
                [[ $(digest "$PUBLISH_TEMP") == "$wanted" ]] || die 'Staged copy checksum mismatch.'
                safe "$ENGINE_HOME" "$name"
                [[ $(digest "$destination") == "$actual" ]] || die "Concurrent HOME edit: $name"
                mv -f -- "$PUBLISH_TEMP" "$destination"
                PUBLISH_TEMP=''
            fi
        done
        check_home
        jq '.phase="deployed"' "$MANIFEST" | save_json "$MANIFEST"
        ;;
    phase)
        load_manifest
        jq -r '.phase' "$MANIFEST"
        ;;
    needs-deploy)
        load_manifest
        jq -r '. as $m | if any(.desired | to_entries[]; $m.home[.key] != .value) then "yes" else "no" end' "$MANIFEST"
        ;;
    base)
        load_manifest
        jq -r '.base' "$MANIFEST"
        ;;
    clear)
        load_manifest
        git -C "$REPO" update-ref -d "refs/macos-config-sync/$MACHINE/pending-local"
        rm -- "$MANIFEST"
        ;;
    *) die 'Unknown engine operation.' ;;
esac
