# SPEC -- nixpkgs-lock-subscribe

## §G GOAL

CLI tool — subscribe nix flake repos to centralized nixpkgs pin via nixpkgs-lock. Rewrites `nixpkgs` input → `nixpkgs.follows = "nixpkgs-lock/nixpkgs"`, installs daily cron workflow for auto-pull. Run once per repo → self-sustaining. `nix run github:pr0d1r2/nixpkgs-lock-subscribe`.

## §C CONSTRAINTS

- C1: Nix flake — `apps.default` via `writeShellApplication`, runnable via `nix run`
- C2: Bash script core — runtime deps: `gh`, `git`, `nix`, `gnused`, `gnugrep`, `jq`
- C3: Public repos only (private = future scope)
- C4: Idempotent — re-run on subscribed repo = no-op | cron fix
- C5: Cross-platform — Linux & macOS (GNU sed via nix, no `open -a`)
- C6: Zero config — derives owner/email from `gh api /user` & `git config`
- C7: Pull model — installs cron in target repo, no cross-repo auth
- C8: MIT license
- C9: Pin pattern currently hardcoded to `nixos-25.11` (→ §T.T4 for future)
- C10: Workflow template embedded — `update-pins.yml` with `peter-evans/create-pull-request`
- C11: CI via nix-lefthook-ci-action — serial chain: linux → linux-arm → macos
- C12: Lefthook shell linting — shellcheck, shfmt, bats-unit, bats-parse
- C13: LLM-generated, validated via CI

## §I INTERFACES

- I.cli.all: `nix run .` → subscribe all public repos with direct nixpkgs pin
- I.cli.glob: `nix run . -- 'nix-*'` → subscribe matching repos
- I.cli.url: `nix run . -- https://github.com/owner/repo` → subscribe single repo
- I.cli.dry: `--dry-run` → show what would change, no PRs (§T.T10, not yet)
- I.cli.status: `--status` → subscription state per repo (§T.T11, not yet)
- I.cli.help: `--help` → usage (§T.T5, not yet)
- I.workflow: `.github/workflows/update-pins.yml` — installed in target repos
- I.branch: `feat/nixpkgs-lock-follows` — PR branch in target repos
- I.cron: downstream cron `30 3 * * *` (5:30 AM CEST) — 30 min after nixpkgs-lock `0 3`

## §V INVARIANTS

- V1: ⊥ hardcoded usernames, emails, repo owners in script
- V2: `sed -i` ! work on both Linux & macOS (GNU sed via nix `writeShellApplication`)
- V3: re-run on subscribed repo with correct cron → zero git operations
- V4: re-run on subscribed repo with wrong cron → PR to fix cron only
- V5: ⊥ PR created if `nix flake lock` fails — report & continue
- V6: ⊥ OS-specific commands (`open -a Safari`, `xdg-open`)
- V7: `--dry-run` ! produce zero side effects (§T.T10, not yet)
- V8: single repo URL mode ! skip "list all repos" API call
- V11: re-run with existing PR → report as succeeded, not failed
- V12: empty repo match → explicit error message, not silent exit
- V9: nixpkgs channel pattern derived from nixpkgs-lock `flake.nix` (§T.T4, not yet — currently hardcoded)
- V10: ∀ target repo → `nix flake check --no-build` passes before PR

## §T TASKS

| id | st | desc | cites |
|----|----|------|-------|
| T1 | x | `flake.nix` with bash script as `apps.default` via `writeShellApplication` | C1,C2 |
| T2 | x | core subscribe logic — rewrite flake.nix, install update-pins.yml, PR | C7,C10,I.workflow |
| T3 | x | cron fix mode — detect drift in already-subscribed repos, PR to correct | V3,V4,I.cron |
| T4 | x | detect nixpkgs channel from nixpkgs-lock `flake.nix` instead of hardcode | C9,V9 |
| T5 | x | CLI: single repo URL (validates owner matches authenticated user) | I.cli.url,V8 |
| T5b | . | CLI: `--help` | I.cli.help |
| T6 | x | CLI: glob pattern as positional arg | I.cli.glob |
| T7 | x | zero config — derive owner/email from gh/git | C6,V1 |
| T8 | x | cross-platform — GNU sed via nix, no OS-specific commands | C5,V2,V6 |
| T9 | x | CI — nix-lefthook-ci-action on 3 platforms | C11 |
| T10 | . | `--dry-run` mode | I.cli.dry,V7 |
| T11 | . | `--status` mode — show subscription state per repo | I.cli.status |
| T12 | x | bats unit tests for current script logic | C12 |
| T13 | x | lefthook config — shellcheck, shfmt, bats, yamllint, etc. | C12 |
| T14 | . | error recovery — partial failure resume, no `--force` push | V5 |
| T15 | x | summary report (succeeded/skipped/failed) | - |
| T16 | x | SPEC.md | - |
| T17 | x | handle existing PR on re-run — report as succeeded | V11 |
| T18 | x | empty pattern match → explicit error message | V12 |
| T19 | x | CI serial chain: linux → linux-arm → macos | C11 |
| T20 | x | check order: nixpkgs-lock before direct pin | V3,V4 |

## §B BUGS

(none yet)
