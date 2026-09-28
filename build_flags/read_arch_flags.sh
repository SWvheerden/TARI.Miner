# shellcheck shell=bash
# Sourced by build_solver.sh and build_pool_miner.sh; not meant to be run.
#
# read_arch_flags ROOT ARCH
#   Sets ARCH_FLAGS (array) and ARCH_FLAGS_SOURCE (string) for a release build.
#   - TARI_ARCH_FLAGS, when non-empty, replaces the file and is split on
#     whitespace. A value of only whitespace means "no extra flags".
#   - Otherwise ROOT/build_flags/ARCH.flags is read: text from '#' to end of
#     line is a comment, blank lines are skipped, CR and surrounding
#     whitespace are dropped, and each remaining word is one flag.
#   - A missing file means no extra flags.
read_arch_flags() {
    local root="$1" arch="$2" file line
    local -a words
    ARCH_FLAGS=()
    if [[ -n "${TARI_ARCH_FLAGS:-}" ]]; then
        ARCH_FLAGS_SOURCE="TARI_ARCH_FLAGS"
        read -r -a words <<< "${TARI_ARCH_FLAGS//$'\r'/ }"
        if [[ ${#words[@]} -gt 0 ]]; then
            ARCH_FLAGS=("${words[@]}")
        fi
        return 0
    fi
    file="$root/build_flags/$arch.flags"
    if [[ ! -f "$file" ]]; then
        ARCH_FLAGS_SOURCE="none, no build_flags/$arch.flags"
        return 0
    fi
    ARCH_FLAGS_SOURCE="build_flags/$arch.flags"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//$'\r'/ }"
        read -r -a words <<< "$line"
        if [[ ${#words[@]} -gt 0 ]]; then
            ARCH_FLAGS+=("${words[@]}")
        fi
    done < "$file"
}

# print_arch_flags ARCH
#   Prints the effective list so every build log records what was compiled.
print_arch_flags() {
    local list="(none)"
    if [[ ${#ARCH_FLAGS[@]} -gt 0 ]]; then
        list="${ARCH_FLAGS[*]}"
    fi
    echo "Arch flags for $1 [$ARCH_FLAGS_SOURCE]: $list"
}
