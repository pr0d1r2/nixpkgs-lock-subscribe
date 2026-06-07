# shellcheck shell=bash
export BATS_LIB_PATH="@BATS_LIB_PATH@/share/bats"
[ -f .git/hooks/pre-commit ] || lefthook install
