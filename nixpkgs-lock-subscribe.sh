# shellcheck shell=bash
#
# nixpkgs-lock-subscribe — Subscribe nix flake repos to centralized nixpkgs pin
#
# Scans all public repositories matching "nix-*" under the authenticated
# GitHub user and performs one of two actions:
#
#   1. Fresh conversion: If a repo pins nixpkgs directly via
#      nixpkgs.url = "github:NixOS/nixpkgs/<channel>", rewrites it to
#      follow nixpkgs-lock (nixpkgs.follows = "nixpkgs-lock/nixpkgs") and
#      adds a daily cron workflow (update-pins.yml) to auto-pull pin updates.
#
#   2. Cron fix: If a repo already uses nixpkgs-lock but its update-pins.yml
#      has a different cron schedule than expected (30 3 * * * = 3:30 UTC),
#      creates a PR to correct it.
#
# For each change, a PR is created on a "feat/nixpkgs-lock-follows" branch.
# Already-converted repos with correct cron are skipped.
#
# Prerequisites:
#   - gh CLI authenticated
#   - git config user.name and user.email set
#   - nix with flake support
#   - SSH access to GitHub repos (git@github.com:...)
#
# Usage:
#   nix run github:pr0d1r2/nixpkgs-lock-subscribe                                        # all public repos
#   nix run github:pr0d1r2/nixpkgs-lock-subscribe -- 'nix-*'                              # only nix-* repos
#   nix run github:pr0d1r2/nixpkgs-lock-subscribe -- https://github.com/pr0d1r2/nix-bm25s # single repo
#

DRY_RUN=0
STATUS_MODE=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --help)
      cat <<'EOF'
Usage: nixpkgs-lock-subscribe [OPTIONS] [PATTERN | URL]

Subscribe nix flake repos to centralized nixpkgs pin via nixpkgs-lock.

Arguments:
  (none)        Subscribe all public repos with direct nixpkgs pin
  PATTERN       Subscribe repos matching glob pattern (e.g. 'nix-*')
  URL           Subscribe a single repo by GitHub URL
                (e.g. https://github.com/OWNER/REPO)

Options:
  --dry-run     Show what would change without making any modifications
  --status      Show subscription state per repo
  --help        Show this help message and exit
EOF
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --status)
      STATUS_MODE=1
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

GITHUB_USER=$(gh api /user --jq .login)
GIT_NAME=$(git config user.name)
GIT_EMAIL=$(git config user.email)

NIXPKGS_CHANNEL=$(gh api "repos/$GITHUB_USER/nixpkgs-lock/contents/flake.nix" --jq '.content' |
  base64 -d |
  sed -n 's/.*nixpkgs\.url = "github:NixOS\/nixpkgs\/\([^"]*\)".*/\1/p')

if [[ -z "$NIXPKGS_CHANNEL" ]]; then
  echo "ERROR: could not detect nixpkgs channel from $GITHUB_USER/nixpkgs-lock flake.nix"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'echo "Workdir: $WORKDIR (not cleaned up for inspection)"' EXIT

ARG=${POSITIONAL[0]:-}

if [[ "$ARG" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
  URL_OWNER="${BASH_REMATCH[1]}"
  URL_REPO="${BASH_REMATCH[2]}"
  if [[ "$URL_OWNER" != "$GITHUB_USER" ]]; then
    echo "ERROR: repo owner '$URL_OWNER' does not match authenticated user '$GITHUB_USER'"
    exit 1
  fi
  REPOS="$URL_REPO"
else
  ALL_REPOS=$(gh repo list "$GITHUB_USER" --limit 500 --json name,isPrivate --jq '.[] | select(.isPrivate == false) | .name' |
    grep -v '^nixpkgs-lock$' | sort)

  if [[ -n "$ARG" ]]; then
    REGEX="^${ARG//\*/.*}$"
    REPOS=$(echo "$ALL_REPOS" | grep -E "$REGEX" || true)
  else
    REPOS=$ALL_REPOS
  fi

  if [[ -z "$REPOS" ]]; then
    echo "No repos matched pattern: ${ARG:-<all>}"
    exit 1
  fi
fi

BRANCH="feat/nixpkgs-lock-follows"

export GH_PROMPT_DISABLED=1

read -r -d '' WORKFLOW <<WORKFLOW_EOF || true
name: Update nixpkgs-lock pin

on:
  schedule:
    - cron: '30 3 * * *'
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - uses: cachix/install-nix-action@v31

      - run: nix flake update nixpkgs-lock

      - run: nix flake check --no-build

      - uses: peter-evans/create-pull-request@v7
        with:
          commit-message: "chore: update nixpkgs-lock pin"
          title: "chore: update nixpkgs-lock pin"
          branch: auto/pin-update
          delete-branch: true
          labels: auto-merge
          author: $GIT_NAME <$GIT_EMAIL>
          committer: $GIT_NAME <$GIT_EMAIL>
WORKFLOW_EOF

declare -a succeeded=()
declare -a skipped=()
declare -a failed=()

for repo in $REPOS; do
  echo ""
  echo "=== $repo ==="
  cd "$WORKDIR" || exit

  if ! git clone --depth 1 "git@github.com:$GITHUB_USER/$repo.git" 2>/dev/null; then
    if [[ $STATUS_MODE -eq 1 ]]; then
      echo "$repo: clone-failed"
    else
      echo "SKIP: clone failed"
      skipped+=("$repo: clone failed")
    fi
    continue
  fi
  cd "$repo" || exit

  if [[ ! -f flake.nix ]]; then
    if [[ $STATUS_MODE -eq 1 ]]; then
      echo "$repo: no-flake"
    else
      echo "SKIP: no flake.nix"
      skipped+=("$repo: no flake.nix")
    fi
    continue
  fi

  if [[ $STATUS_MODE -eq 1 ]]; then
    if grep -q 'nixpkgs-lock' flake.nix; then
      PINS_WORKFLOW=".github/workflows/update-pins.yml"
      if [[ -f "$PINS_WORKFLOW" ]] && ! grep -q "cron: '30 3 \* \* \*'" "$PINS_WORKFLOW"; then
        current_cron=$(grep 'cron:' "$PINS_WORKFLOW" | head -1 | xargs)
        echo "$repo: cron-drift ($current_cron)"
      else
        echo "$repo: subscribed"
      fi
    elif grep -q "nixpkgs.url = \"github:NixOS/nixpkgs/$NIXPKGS_CHANNEL\"" flake.nix; then
      echo "$repo: eligible"
    else
      echo "$repo: no-nixpkgs-pin"
    fi
    continue
  fi

  if grep -q 'nixpkgs-lock' flake.nix; then
    PINS_WORKFLOW=".github/workflows/update-pins.yml"
    if [[ -f "$PINS_WORKFLOW" ]] && ! grep -q "cron: '30 3 \* \* \*'" "$PINS_WORKFLOW"; then
      current_cron=$(grep 'cron:' "$PINS_WORKFLOW" | head -1 | xargs)
      if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY RUN: would fix cron for $repo ($current_cron -> '30 3 * * *')"
        succeeded+=("$repo (would fix cron)")
      else
        existing_pr=$(gh pr list --repo "$GITHUB_USER/$repo" --head "$BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)
        if [[ -n "$existing_pr" ]]; then
          echo "PR already exists: $existing_pr"
          succeeded+=("$repo (existing PR)")
        else
          echo "FIX CRON: $repo ($current_cron -> '30 3 * * *')"
          git checkout -b "$BRANCH"
          sed -i "s|cron: '.*'|cron: '30 3 * * *'|" "$PINS_WORKFLOW"
          git add "$PINS_WORKFLOW"
          git commit -m "fix: update nixpkgs-lock pin cron to 3:30 UTC"
          if ! git push -u origin "$BRANCH" 2>/dev/null; then
            git push --delete origin "$BRANCH" 2>/dev/null || true
            if ! git push -u origin "$BRANCH"; then
              echo "FAIL: push"
              failed+=("$repo: push failed")
              continue
            fi
          fi
          pr_output=$(gh pr create \
            --repo "$GITHUB_USER/$repo" \
            --head "$BRANCH" \
            --title "Fix nixpkgs-lock pin update cron schedule" \
            --body "Update cron from $current_cron to 3:30 UTC (5:30 AM CEST)." 2>&1) || true

          if [[ "$pr_output" =~ already\ exists ]]; then
            existing_url=$(echo "$pr_output" | grep -oE 'https://[^ ]+')
            echo "PR already exists: $existing_url (branch updated)"
            succeeded+=("$repo (updated existing PR)")
          elif [[ "$pr_output" =~ ^https:// ]]; then
            echo "PR: $pr_output"
            succeeded+=("$repo (cron fix)")
          else
            echo "FAIL: PR creation"
            failed+=("$repo: PR creation failed")
            continue
          fi
        fi
      fi
    else
      echo "SKIP: already converted, cron OK"
      skipped+=("$repo: already converted")
    fi
    continue
  fi

  if ! grep -q "nixpkgs.url = \"github:NixOS/nixpkgs/$NIXPKGS_CHANNEL\"" flake.nix; then
    echo "SKIP: no nixpkgs $NIXPKGS_CHANNEL direct pin"
    skipped+=("$repo: no direct nixpkgs pin")
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN: would subscribe $repo"
    succeeded+=("$repo (would subscribe)")
  else
    existing_pr=$(gh pr list --repo "$GITHUB_USER/$repo" --head "$BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)
    if [[ -n "$existing_pr" ]]; then
      echo "PR already exists: $existing_pr"
      succeeded+=("$repo (existing PR)")
    else
      git checkout -b "$BRANCH"

      # Add nixpkgs-lock input, flip nixpkgs to follows
      sed -i \
        "s|nixpkgs.url = \"github:NixOS/nixpkgs/$NIXPKGS_CHANNEL\";|nixpkgs-lock.url = \"github:$GITHUB_USER/nixpkgs-lock\";\n    nixpkgs.follows = \"nixpkgs-lock/nixpkgs\";|" \
        flake.nix

      # Add update-pins workflow
      mkdir -p .github/workflows
      echo "$WORKFLOW" >.github/workflows/update-pins.yml

      # Resolve only nixpkgs-lock input, don't touch other inputs
      if ! nix flake update nixpkgs-lock 2>/dev/null; then
        echo "FAIL: nix flake update"
        failed+=("$repo: nix flake update failed")
        continue
      fi

      git add -A
      git commit -m "chore: switch nixpkgs pin to nixpkgs-lock follows

Uses $GITHUB_USER/nixpkgs-lock as centralized nixpkgs pin.
Adds daily cron to pull pin updates automatically."

      if ! git push -u origin "$BRANCH" 2>/dev/null; then
        git push --delete origin "$BRANCH" 2>/dev/null || true
        if ! git push -u origin "$BRANCH"; then
          echo "FAIL: push"
          failed+=("$repo: push failed")
          continue
        fi
      fi

      pr_output=$(gh pr create \
        --repo "$GITHUB_USER/$repo" \
        --head "$BRANCH" \
        --title "Switch to centralized nixpkgs-lock pin" \
        --body "$(
          cat <<PR_EOF
## Summary
- Switch \`nixpkgs\` from direct pin to \`nixpkgs.follows = "nixpkgs-lock/nixpkgs"\`
- Add daily cron workflow (\`update-pins.yml\`) to auto-pull pin updates

## Context
Part of centralized nixpkgs version management via [$GITHUB_USER/nixpkgs-lock](https://github.com/$GITHUB_USER/nixpkgs-lock).
PR_EOF
        )" 2>&1) || true

      if [[ "$pr_output" =~ already\ exists ]]; then
        existing_url=$(echo "$pr_output" | grep -oE 'https://[^ ]+')
        echo "PR already exists: $existing_url (branch updated)"
        succeeded+=("$repo (updated existing PR)")
      elif [[ "$pr_output" =~ ^https:// ]]; then
        echo "PR: $pr_output"
        succeeded+=("$repo")
      else
        echo "FAIL: PR creation"
        failed+=("$repo: PR creation failed")
        continue
      fi

      echo "DONE: $repo"
    fi
  fi
done

if [[ $STATUS_MODE -ne 1 ]]; then
  echo ""
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "========== DRY RUN SUMMARY =========="
  else
    echo "========== SUMMARY =========="
  fi
  echo "Succeeded: ${#succeeded[@]}"
  for r in "${succeeded[@]+"${succeeded[@]}"}"; do echo "  ✓ $r"; done
  echo "Skipped: ${#skipped[@]}"
  for r in "${skipped[@]+"${skipped[@]}"}"; do echo "  - $r"; done
  echo "Failed: ${#failed[@]}"
  for r in "${failed[@]+"${failed[@]}"}"; do echo "  ✗ $r"; done
  echo "Workdir: $WORKDIR"
fi
