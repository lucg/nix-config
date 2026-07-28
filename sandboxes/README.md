# sandboxes

Docker Sandbox (`sbx`) assets used on this machine.

| Path | Role |
| --- | --- |
| [`nix-agent/`](nix-agent/) | Custom templates: official `sandbox-templates` + Nix |
| [`kits/`](kits/) | Mixin kits (network allowlists); stack with `--kit` |

## nix-agent templates

Extends `docker/sandbox-templates:<variant>` so agent wiring and the sbx credential proxy stay intact; Nix is layered on top for flaked projects.

Variants (no `-docker` siblings): `claude-code`, `cursor-agent`, `gemini`.

### Build

```bash
cd sandboxes/nix-agent
docker buildx bake                          # all variants
docker buildx bake nix-agent-claude-code    # one variant
```

### Load into sbx

The sbx runtime does not share the host Docker image store:

```bash
docker image save nix-agent:claude-code -o /tmp/nix-agent-claude-code.tar
sbx template load /tmp/nix-agent-claude-code.tar
```

Repeat for other tags after rebuilding. Recreate existing sandboxes to pick up a new template.

### Run

Select the matching sbx agent for the chosen template variant:

```bash
sbx run --template nix-agent:claude-code claude
sbx run --template nix-agent:cursor-agent cursor
sbx run --template nix-agent:gemini gemini
```

## Kits

Stack mixin network allowlists from `kits/` with `--kit`:

```bash
sbx run claude \
  --template nix-agent:claude-code \
  --kit ~/nix-config/sandboxes/kits/nix \
  --kit ./sbx/espressif
```

Copy `kits/espressif` into a project as `sbx/espressif` when needed. Prefer kits over one-off `sbx policy allow network "..."`.

Note: `docker buildx bake` runs on the host (outside sbx network policy). Template image builds may need outbound access to `install.determinate.systems`; that is unrelated to sandbox kit allowlists.

## sbxa

`sbxa` is a small helper (installed via the flake) that idempotently create-or-attaches nix-agent sandboxes for the current workspace.

```bash
sbxa                  # pick agent, create-or-attach for cwd
sbxa cursor           # cursor agent for cwd
sbxa cursor ~/proj    # explicit workspace
sbxa --kit ./sbx/espressif cursor
sbxa name cursor      # print derived name
sbxa ls               # list managed sandboxes (agent+…)
sbxa rm cursor        # remove cursor sandbox for cwd
sbxa rm cursor+nix-config.sbx-helper
```

Names look like `cursor+nix-config.sbx-helper` (`{agent}+` + `$HOME`-relative path with `/` → `.`). If a sandbox with that name already exists (`sbx ls --json`), `sbxa` attaches with `sbx run --name`; otherwise it creates with the matching `nix-agent:*` template and stacked kits:

1. Store-pinned `kits/nix` (override with `SBXA_KIT`)
2. Each `$workspace/sbx/*/spec.yaml` directory (auto-discovered)
3. Paths in `SBXA_EXTRA_KITS` (colon-separated)
4. Each `--kit PATH`

```bash
# project-local kits under ./sbx/ are picked up automatically
mkdir -p sbx && cp -r ~/nix-config/sandboxes/kits/espressif sbx/
sbxa cursor

# or pass explicitly / via env
sbxa --kit ./sbx/espressif --kit /path/to/other cursor
SBXA_EXTRA_KITS=./sbx/espressif:/path/to/other sbxa cursor

# live kit checkout without rebuilding sbxa
SBXA_KIT=~/nix-config/sandboxes/kits/nix sbxa cursor
```

Kits only apply at create time; attach ignores `--kit` / `SBXA_EXTRA_KITS`. There is no auto-prune; use `sbxa ls` / `sbxa rm` explicitly.
