#!/bin/zsh

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <file1.s> <file2.s>"
    exit 1
fi

FILE1="$1"
FILE2="$2"

clean_asm() {
    cat "$1" | \
        # 1. Replace numbers after .long with X
        sed -E 's/(\.long[[:space:]]+)[0-9]+/\1X/g' | \
        sed -E 's/(\.quad[[:space:]]+)\.Ltmp[0-9]+/\1X/g' | \
        # 2. Normalize Zig anonymous function IDs (__anon_1234 -> __anon_X)
        sed -E 's/__anon_[0-9]+/__anon_X/g' | \
        sed -E 's/__enum_[0-9]+/__enum_X/g' | \
        sed -E 's/__struct_[0-9]+/__struct_X/g'
}

if command -v colordiff &> /dev/null; then
    colordiff -u <(clean_asm "$FILE1") <(clean_asm "$FILE2")
else
    diff -u <(clean_asm "$FILE1") <(clean_asm "$FILE2")
fi
