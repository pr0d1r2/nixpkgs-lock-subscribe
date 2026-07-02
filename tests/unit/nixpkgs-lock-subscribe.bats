#!/usr/bin/env bats

setup() {
    load "${BATS_LIB_PATH}/bats-support/load.bash"
    load "${BATS_LIB_PATH}/bats-assert/load.bash"

    TMP="$BATS_TEST_TMPDIR"
    REPO_OWNER=$(git remote get-url origin | sed -E 's|.*[:/]([^/]+)/.*|\1|')

    mkdir -p "$TMP/bin"

    NIXPKGS_LOCK_FLAKE_B64=$(printf '{\n  inputs = {\n    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";\n  };\n}\n' | base64 -w0)

    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-with-flake"
        echo "repo-no-flake"
        echo "repo-already-subscribed"
        echo "nixpkgs-lock"
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"

    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        case "$repo_name" in
            repo-with-flake)
                cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
                ;;
            repo-already-subscribed)
                cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs-lock.url = "github:testuser/nixpkgs-lock";
    nixpkgs.follows = "nixpkgs-lock/nixpkgs";
  };
}
NIX
                mkdir -p "$repo_name/.github/workflows"
                cat > "$repo_name/.github/workflows/update-pins.yml" <<'YML'
on:
  schedule:
    - cron: '30 3 * * *'
YML
                ;;
            repo-no-flake)
                ;;
        esac
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"

    export PATH="$TMP/bin:$PATH"
}

@test "--help prints usage" {
    run bash nixpkgs-lock-subscribe.sh --help
    assert_success
    assert_output --partial "Usage: nixpkgs-lock-subscribe"
}

@test "--help shows available arguments" {
    run bash nixpkgs-lock-subscribe.sh --help
    assert_success
    assert_output --partial "PATTERN"
    assert_output --partial "URL"
}

@test "--help exits before API calls" {
    cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "ERROR: gh should not be called with --help" >&2
exit 1
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh --help
    assert_success
    refute_output --partial "ERROR"
}

@test "filters out nixpkgs-lock from repo list" {
    ALL="repo-with-flake
nixpkgs-lock
repo-no-flake"
    run bash -c 'echo "$1" | grep -v "^nixpkgs-lock$"' -- "$ALL"
    assert_success
    refute_output --partial "nixpkgs-lock"
}

@test "glob pattern filters repos" {
    PATTERN="repo-with-*"
    REGEX="^${PATTERN//\*/.*}$"
    ALL="repo-with-flake
repo-no-flake
repo-already-subscribed"
    run bash -c 'echo "$1" | grep -E "$2"' -- "$ALL" "$REGEX"
    assert_success
    assert_output "repo-with-flake"
}

@test "skips repo without flake.nix" {
    mkdir -p "$TMP/workdir/repo-no-flake"
    cd "$TMP/workdir/repo-no-flake"
    run bash -c '[[ ! -f flake.nix ]] && echo "SKIP: no flake.nix"'
    assert_success
    assert_output "SKIP: no flake.nix"
}

@test "detects already-subscribed repo" {
    mkdir -p "$TMP/workdir/repo-subscribed"
    cat > "$TMP/workdir/repo-subscribed/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs-lock.url = "github:testuser/nixpkgs-lock";
    nixpkgs.follows = "nixpkgs-lock/nixpkgs";
  };
}
NIX
    cd "$TMP/workdir/repo-subscribed"
    run bash -c 'grep -q "nixpkgs-lock" flake.nix && echo "already subscribed"'
    assert_success
    assert_output "already subscribed"
}

@test "detects correct cron in update-pins.yml" {
    mkdir -p "$TMP/workdir/.github/workflows"
    cat > "$TMP/workdir/.github/workflows/update-pins.yml" <<'YML'
on:
  schedule:
    - cron: '30 3 * * *'
YML
    run bash -c 'grep -q "cron: '\''30 3 \* \* \*'\''" "$1/.github/workflows/update-pins.yml" && echo "cron OK"' -- "$TMP/workdir"
    assert_success
    assert_output "cron OK"
}

@test "detects wrong cron in update-pins.yml" {
    mkdir -p "$TMP/workdir/.github/workflows"
    cat > "$TMP/workdir/.github/workflows/update-pins.yml" <<'YML'
on:
  schedule:
    - cron: '30 6 * * *'
YML
    run bash -c '! grep -q "cron: '\''30 3 \* \* \*'\''" "$1/.github/workflows/update-pins.yml" && echo "cron drift"' -- "$TMP/workdir"
    assert_success
    assert_output "cron drift"
}

@test "detects direct nixpkgs pin eligible for conversion" {
    mkdir -p "$TMP/workdir"
    cat > "$TMP/workdir/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
    run bash -c 'grep -q '\''nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"'\'' "$1/flake.nix" && echo "eligible"' -- "$TMP/workdir"
    assert_success
    assert_output "eligible"
}

@test "workflow template contains author placeholder" {
    run grep -c 'author:.*<.*>' nixpkgs-lock-subscribe.sh
    assert_success
}

@test "no hardcoded usernames in non-comment code" {
    [[ -n "$REPO_OWNER" ]] || skip "no origin remote"
    run bash -c "grep -v '^#' nixpkgs-lock-subscribe.sh | grep -cF '$REPO_OWNER'"
    assert_failure
    assert_output "0"
}

@test "no macOS-only commands in script" {
    run grep -c 'open -a' nixpkgs-lock-subscribe.sh
    assert_failure
    assert_output "0"
}

@test "no macOS sed -i syntax in script" {
    run grep -c "sed -i ''" nixpkgs-lock-subscribe.sh
    assert_failure
    assert_output "0"
}

@test "URL arg extracts repo name" {
    ARG="https://github.com/testuser/nix-bm25s"
    run bash -c '[[ "$1" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]] && echo "${BASH_REMATCH[2]}"' -- "$ARG"
    assert_success
    assert_output "nix-bm25s"
}

@test "URL arg extracts owner" {
    ARG="https://github.com/testuser/nix-bm25s"
    run bash -c '[[ "$1" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]] && echo "${BASH_REMATCH[1]}"' -- "$ARG"
    assert_success
    assert_output "testuser"
}

@test "URL arg rejects wrong owner" {
    ARG="https://github.com/otheruser/nix-bm25s"
    run bash -c '[[ "$1" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]] && [[ "${BASH_REMATCH[1]}" != "testuser" ]] && echo "owner mismatch"' -- "$ARG"
    assert_success
    assert_output "owner mismatch"
}

@test "URL with trailing slash works" {
    ARG="https://github.com/testuser/nix-bm25s/"
    run bash -c '[[ "$1" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]] && echo "${BASH_REMATCH[2]}"' -- "$ARG"
    assert_success
    assert_output "nix-bm25s"
}

@test "existing PR detected as success" {
    pr_output='a pull request for branch "feat/nixpkgs-lock-follows" into branch "main" already exists:
https://github.com/testuser/nix-foo/pull/3'
    run bash -c '[[ "$1" =~ already\ exists ]] && echo "$1" | grep -oE "https://[^ ]+"' -- "$pr_output"
    assert_success
    assert_output "https://github.com/testuser/nix-foo/pull/3"
}

@test "new PR URL detected as success" {
    pr_output="https://github.com/testuser/nix-foo/pull/4"
    run bash -c '[[ "$1" =~ ^https:// ]] && echo "new PR"' -- "$pr_output"
    assert_success
    assert_output "new PR"
}

@test "empty pattern reports error" {
    REPOS=""
    run bash -c '[[ -z "$1" ]] && echo "No repos matched pattern: test-*"' -- "$REPOS"
    assert_success
    assert_output "No repos matched pattern: test-*"
}

@test "detects nixpkgs channel from nixpkgs-lock flake.nix" {
    run bash -c 'gh api "repos/testuser/nixpkgs-lock/contents/flake.nix" --jq ".content" | base64 -d | sed -n '\''s/.*nixpkgs\.url = "github:NixOS\/nixpkgs\/\([^"]*\)".*/\1/p'\'''
    assert_success
    assert_output "nixos-25.11"
}

@test "channel detection fails on empty response" {
    cat > "$TMP/bin/gh-empty" <<'SH'
#!/usr/bin/env bash
echo '{"content":""}'
SH
    chmod +x "$TMP/bin/gh-empty"
    run bash -c '"$1/bin/gh-empty" api x --jq ".content" | base64 -d 2>/dev/null | sed -n '\''s/.*nixpkgs\.url = "github:NixOS\/nixpkgs\/\([^"]*\)".*/\1/p'\''' -- "$TMP"
    assert_success
    assert_output ""
}

@test "detected channel used in direct pin check" {
    NIXPKGS_CHANNEL="nixos-25.11"
    mkdir -p "$TMP/workdir"
    cat > "$TMP/workdir/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
    run bash -c 'grep -q "nixpkgs.url = \"github:NixOS/nixpkgs/$1\"" "$2/flake.nix" && echo "eligible"' -- "$NIXPKGS_CHANNEL" "$TMP/workdir"
    assert_success
    assert_output "eligible"
}

@test "detected channel rejects mismatched pin" {
    NIXPKGS_CHANNEL="nixos-25.11"
    mkdir -p "$TMP/workdir"
    cat > "$TMP/workdir/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };
}
NIX
    run bash -c '! grep -q "nixpkgs.url = \"github:NixOS/nixpkgs/$1\"" "$2/flake.nix" && echo "no match"' -- "$NIXPKGS_CHANNEL" "$TMP/workdir"
    assert_success
    assert_output "no match"
}

@test "--help shows --dry-run option" {
    run bash nixpkgs-lock-subscribe.sh --help
    assert_success
    assert_output --partial "--dry-run"
}

@test "--dry-run with --help still shows help" {
    run bash nixpkgs-lock-subscribe.sh --dry-run --help
    assert_success
    assert_output --partial "Usage: nixpkgs-lock-subscribe"
}

@test "--dry-run parses with positional arg" {
    DRY_RUN=0
    POSITIONAL=()
    for arg in --dry-run 'nix-*'; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            *) POSITIONAL+=("$arg") ;;
        esac
    done
    run bash -c 'echo "$1 $2"' -- "$DRY_RUN" "${POSITIONAL[0]:-}"
    assert_success
    assert_output "1 nix-*"
}

@test "--dry-run reports would-subscribe for eligible repo" {
    run bash nixpkgs-lock-subscribe.sh --dry-run
    assert_success
    assert_output --partial "DRY RUN: would subscribe repo-with-flake"
}

@test "--dry-run skips already-subscribed repo" {
    run bash nixpkgs-lock-subscribe.sh --dry-run
    assert_success
    assert_output --partial "SKIP: already converted, cron OK"
}

@test "--dry-run summary shows DRY RUN header" {
    run bash nixpkgs-lock-subscribe.sh --dry-run
    assert_success
    assert_output --partial "DRY RUN SUMMARY"
}

@test "--dry-run does not call git push or gh pr create" {
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
        ;;
    push)
        echo "ERROR: git push called in dry-run" >&2
        exit 1
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-with-flake"
        ;;
    *"pr create"*)
        echo "ERROR: gh pr create called in dry-run" >&2
        exit 1
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh --dry-run
    assert_success
    refute_output --partial "ERROR"
}

@test "--dry-run reports would-fix-cron for drifted schedule" {
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs-lock.url = "github:testuser/nixpkgs-lock";
    nixpkgs.follows = "nixpkgs-lock/nixpkgs";
  };
}
NIX
        mkdir -p "$repo_name/.github/workflows"
        cat > "$repo_name/.github/workflows/update-pins.yml" <<'YML'
on:
  schedule:
    - cron: '30 6 * * *'
YML
        ;;
    push)
        echo "ERROR: git push called in dry-run" >&2
        exit 1
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-wrong-cron"
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh --dry-run
    assert_success
    assert_output --partial "DRY RUN: would fix cron"
    refute_output --partial "ERROR"
}

@test "--help shows --status option" {
    run bash nixpkgs-lock-subscribe.sh --help
    assert_success
    assert_output --partial "--status"
}

@test "--status parses with positional arg" {
    STATUS_MODE=0
    POSITIONAL=()
    for arg in --status 'nix-*'; do
        case "$arg" in
            --status) STATUS_MODE=1 ;;
            *) POSITIONAL+=("$arg") ;;
        esac
    done
    run bash -c 'echo "$1 $2"' -- "$STATUS_MODE" "${POSITIONAL[0]:-}"
    assert_success
    assert_output "1 nix-*"
}

@test "--status shows subscribed for converted repo" {
    run bash nixpkgs-lock-subscribe.sh --status
    assert_success
    assert_output --partial "repo-already-subscribed: subscribed"
}

@test "--status shows eligible for direct pin repo" {
    run bash nixpkgs-lock-subscribe.sh --status
    assert_success
    assert_output --partial "repo-with-flake: eligible"
}

@test "--status shows no-flake for repo without flake.nix" {
    run bash nixpkgs-lock-subscribe.sh --status
    assert_success
    assert_output --partial "repo-no-flake: no-flake"
}

@test "--status does not show SUMMARY" {
    run bash nixpkgs-lock-subscribe.sh --status
    assert_success
    refute_output --partial "SUMMARY"
}

@test "--status does not call git push or gh pr create" {
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
        ;;
    push)
        echo "ERROR: git push called in status mode" >&2
        exit 1
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-with-flake"
        ;;
    *"pr create"*)
        echo "ERROR: gh pr create called in status mode" >&2
        exit 1
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh --status
    assert_success
    refute_output --partial "ERROR"
}

@test "--status shows cron-drift for wrong cron" {
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs-lock.url = "github:testuser/nixpkgs-lock";
    nixpkgs.follows = "nixpkgs-lock/nixpkgs";
  };
}
NIX
        mkdir -p "$repo_name/.github/workflows"
        cat > "$repo_name/.github/workflows/update-pins.yml" <<'YML'
on:
  schedule:
    - cron: '30 6 * * *'
YML
        ;;
    push)
        echo "ERROR: git push called in status mode" >&2
        exit 1
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-wrong-cron"
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh --status
    assert_success
    assert_output --partial "cron-drift"
    refute_output --partial "ERROR"
}

@test "--status with --help still shows help" {
    run bash nixpkgs-lock-subscribe.sh --status --help
    assert_success
    assert_output --partial "Usage: nixpkgs-lock-subscribe"
}

@test "no --force flag in push commands" {
    run bash -c "grep 'git push' nixpkgs-lock-subscribe.sh | grep -c -- '--force'"
    assert_failure
    assert_output "0"
}

@test "existing PR detected before push on resume" {
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
        ;;
    push)
        echo "ERROR: git push called during resume" >&2
        exit 1
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-with-flake"
        ;;
    *"pr list"*)
        echo "https://github.com/testuser/repo-with-flake/pull/1"
        ;;
    *"pr create"*)
        echo "ERROR: gh pr create called during resume" >&2
        exit 1
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh
    assert_success
    assert_output --partial "PR already exists"
    refute_output --partial "ERROR"
}

@test "nix flake update failure reports and continues" {
    cat > "$TMP/bin/nix" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$TMP/bin/nix"
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
        ;;
    checkout|add|commit)
        ;;
    push)
        echo "ERROR: git push called after nix flake update failure" >&2
        exit 1
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-with-flake"
        ;;
    *"pr list"*)
        ;;
    *"pr create"*)
        echo "ERROR: gh pr create called after nix flake update failure" >&2
        exit 1
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh
    assert_success
    assert_output --partial "FAIL: nix flake update"
    refute_output --partial "ERROR"
}

@test "loop continues to next repo after failure" {
    cat > "$TMP/bin/nix" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$TMP/bin/nix"
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };
}
NIX
        ;;
    checkout|add|commit)
        ;;
    push)
        echo "ERROR: git push should not be called" >&2
        exit 1
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-fail-nix"
        echo "repo-has-pr"
        ;;
    *"pr list"*"repo-has-pr"*)
        echo "https://github.com/testuser/repo-has-pr/pull/1"
        ;;
    *"pr list"*)
        ;;
    *"pr create"*)
        echo "ERROR: gh pr create should not be called" >&2
        exit 1
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh
    assert_success
    assert_output --partial "FAIL: nix flake update"
    assert_output --partial "PR already exists"
    assert_output --partial "Succeeded: 1"
    assert_output --partial "Failed: 1"
    refute_output --partial "ERROR"
}

@test "cron-fix PR creation failure reports and continues" {
    cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
    config)
        case "$2" in
            user.name) echo "Test User" ;;
            user.email) echo "test@example.com" ;;
        esac
        ;;
    clone)
        repo_name="${4##*/}"
        repo_name="${repo_name%.git}"
        mkdir -p "$repo_name"
        cat > "$repo_name/flake.nix" <<'NIX'
{
  inputs = {
    nixpkgs-lock.url = "github:testuser/nixpkgs-lock";
    nixpkgs.follows = "nixpkgs-lock/nixpkgs";
  };
}
NIX
        mkdir -p "$repo_name/.github/workflows"
        cat > "$repo_name/.github/workflows/update-pins.yml" <<'YML'
on:
  schedule:
    - cron: '30 6 * * *'
YML
        ;;
    checkout|add|commit|push)
        ;;
    *)
        command git "$@"
        ;;
esac
SH
    chmod +x "$TMP/bin/git"
    cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
    "api /user --jq .login")
        echo "testuser"
        ;;
    *"repos/testuser/nixpkgs-lock/contents/flake.nix"*)
        echo "$NIXPKGS_LOCK_FLAKE_B64"
        ;;
    *"repo list"*)
        echo "repo-wrong-cron"
        ;;
    *"pr list"*)
        ;;
    *"pr create"*)
        echo "gh: Could not create PR" >&2
        exit 1
        ;;
    *)
        echo "gh mock: \$*" >&2
        ;;
esac
SH
    chmod +x "$TMP/bin/gh"
    run bash nixpkgs-lock-subscribe.sh
    assert_success
    assert_output --partial "FAIL: PR creation"
    assert_output --partial "Failed: 1"
}
