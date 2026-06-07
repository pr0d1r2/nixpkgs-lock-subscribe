#!/usr/bin/env bats

setup() {
    load "${BATS_LIB_PATH}/bats-support/load.bash"
    load "${BATS_LIB_PATH}/bats-assert/load.bash"

    TMPDIR="$(mktemp -d)"
    git init "$TMPDIR/repo" >/dev/null 2>&1
    mkdir -p "$TMPDIR/repo/.git/hooks"
    touch "$TMPDIR/repo/.git/hooks/pre-commit"

    sed 's|@BATS_LIB_PATH@|/test/lib|' dev.sh > "$TMPDIR/dev.sh"

    mkdir -p "$TMPDIR/bin"
    cat > "$TMPDIR/bin/lefthook" <<'SH'
#!/usr/bin/env bash
echo "lefthook $*" >> "$LEFTHOOK_LOG"
SH
    chmod +x "$TMPDIR/bin/lefthook"
}

teardown() {
    rm -rf "$TMPDIR"
}

@test "sets BATS_LIB_PATH from placeholder" {
    cd "$TMPDIR/repo"
    run bash -c 'unset BATS_LIB_PATH; source "$1"; echo "$BATS_LIB_PATH"' -- "$TMPDIR/dev.sh"
    assert_success
    assert_output "/test/lib/share/bats"
}

@test "runs lefthook install when hooks are missing" {
    cd "$TMPDIR/repo"
    rm "$TMPDIR/repo/.git/hooks/pre-commit"
    # shellcheck disable=SC2030
    export PATH="$TMPDIR/bin:$PATH"
    # shellcheck disable=SC2030
    export LEFTHOOK_LOG="$TMPDIR/log"
    # shellcheck disable=SC1091
    source "$TMPDIR/dev.sh"
    assert [ -f "$LEFTHOOK_LOG" ]
    run cat "$LEFTHOOK_LOG"
    assert_output "lefthook install"
}

@test "skips lefthook install when hooks exist" {
    cd "$TMPDIR/repo"
    # shellcheck disable=SC2031
    export PATH="$TMPDIR/bin:$PATH"
    # shellcheck disable=SC2031
    export LEFTHOOK_LOG="$TMPDIR/log"
    # shellcheck disable=SC1091
    source "$TMPDIR/dev.sh"
    assert [ ! -f "$LEFTHOOK_LOG" ]
}
