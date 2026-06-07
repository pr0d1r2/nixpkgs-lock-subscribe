# nixpkgs-lock-subscribe

Subscribe your nix flake repos to a centralized nixpkgs pin via [nixpkgs-lock](https://github.com/pr0d1r2/nixpkgs-lock).

Scans your public GitHub repositories and rewrites direct `nixpkgs` pins to follow `nixpkgs-lock/nixpkgs`, then installs a daily cron workflow to auto-pull pin updates.

## How it works

For each matching repo:

1. **Fresh conversion** -- if the repo pins `nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"` directly, rewrites it to `nixpkgs.follows = "nixpkgs-lock/nixpkgs"` and adds a daily cron workflow (`update-pins.yml`)
2. **Cron fix** -- if the repo already uses nixpkgs-lock but the cron schedule drifted, creates a PR to correct it to `30 3 * * *` (5:30 AM CEST)
3. **Skip** -- already converted repos with correct cron are left alone

Each change is submitted as a PR on a `feat/nixpkgs-lock-follows` branch.

## Usage

```bash
# Subscribe all public repos with a direct nixpkgs pin
nix run github:pr0d1r2/nixpkgs-lock-subscribe

# Only repos matching a glob
nix run github:pr0d1r2/nixpkgs-lock-subscribe -- 'nix-*'

# Single repo by URL
nix run github:pr0d1r2/nixpkgs-lock-subscribe -- https://github.com/pr0d1r2/nix-bm25s
```

## Prerequisites

- `gh` CLI authenticated (`gh auth login`)
- `git config user.name` and `user.email` set
- SSH access to your GitHub repos (`git@github.com:...`)

Everything else (git, jq, gnused, gnugrep, coreutils) is provided by the nix flake.

## What gets installed in target repos

- **`flake.nix` changes**: `nixpkgs-lock` input added, `nixpkgs` switched to `follows`
- **`.github/workflows/update-pins.yml`**: daily cron (3:30 UTC) that runs `nix flake update nixpkgs-lock`, checks with `nix flake check --no-build`, and opens a PR via `peter-evans/create-pull-request`

## Development

```bash
# Enter dev shell
nix develop

# Run tests
bats tests/unit/

# Run linters (via lefthook)
lefthook run pre-commit
```

## License

MIT
