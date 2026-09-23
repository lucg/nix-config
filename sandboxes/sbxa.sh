# sbxa — idempotent create-or-attach for nix-agent sandboxes.
# Packaged via writeShellApplication; @storeKit@ is substituted at build time.

set -euo pipefail

AGENTS=(cursor claude gemini)
MAX_NAME=63
DEFAULT_KIT="@storeKit@"
EXTRA_KITS=()
AGENT_ARGS=()
CLONE=0

template_for() {
  case "$1" in
    cursor) printf '%s\n' "nix-agent:cursor-agent" ;;
    claude) printf '%s\n' "nix-agent:claude-code" ;;
    gemini) printf '%s\n' "nix-agent:gemini" ;;
    *) return 1 ;;
  esac
}

is_agent() {
  template_for "$1" >/dev/null 2>&1
}

die() {
  printf 'sbxa: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  sbxa [--clone] [--kit PATH]... [agent] [path] [-- AGENT_ARGS...]
  sbxa run [--clone] [--kit PATH]... [agent] [path] [-- AGENT_ARGS...]
  sbxa name [--clone] [agent] [path]
  sbxa fetch [agent] [path]
  sbxa ls
  sbxa rm [--clone] [agent|name]

Clone mode (--clone): the agent works in a private git clone inside the
sandbox (sbx run --clone) instead of the bind-mounted workspace. Direct and
clone sandboxes coexist under distinct names (agent.slug vs agent-clone.slug).
Commits come back via "sbxa fetch", which runs git fetch sandbox-<name> in the
host repo and lists the fetched branches.

On create, kits are stacked in order:
  1. baked-in nix kit (override with SBXA_KIT)
  2. each $workspace/sbx/*/spec.yaml directory (auto)
  3. each path in SBXA_EXTRA_KITS (colon-separated)
  4. each --kit PATH

Anything after "--" is forwarded to the agent (sbx run ... -- AGENT_ARGS),
on both create and attach, e.g.: sbxa claude -- --continue

agents: cursor, claude, gemini
env:    SBXA_KIT         override baked-in nix kit path
        SBXA_EXTRA_KITS  extra kit paths (colon-separated)
EOF
}

sandbox_names() {
  command -v sbx >/dev/null 2>&1 || die "sbx not found on PATH"
  local json
  json=$(sbx ls --json) || die "sbx ls --json failed"
  jq -r '.. | objects | select(has("name")) | .name' <<<"$json" | sort -u
}

name_exists() {
  local needle="$1"
  sandbox_names | grep -Fxq -- "$needle"
}

abs_path() {
  local p="$1"
  local resolved
  [[ -d "$p" ]] || die "workspace is not a directory: $p"
  resolved=$(cd "$p" && pwd -P) || die "cannot access workspace: $p"
  printf '%s\n' "$resolved"
}

path_slug() {
  local abs="$1"
  local home="${HOME%/}"
  local rel

  if [[ "$abs" == "$home" ]]; then
    rel="home"
  elif [[ "$abs" == "$home"/* ]]; then
    rel="${abs#"$home"/}"
  else
    rel="${abs#/}"
  fi

  local slug="${rel//\//.}"
  # sbx names: letters, numbers, hyphens, underscores, periods
  slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/\.+/./g; s/^-+//; s/-+$//; s/^\.+//; s/\.+$//')
  if [[ -z "$slug" ]]; then
    slug="workspace"
  fi
  printf '%s\n' "$slug"
}

path_hash() {
  printf '%s' "$1" | sha256sum | cut -c1-8
}

# Sandbox name prefix: "<agent>" in direct mode, "<agent>-clone" in clone mode.
agent_label() {
  if ((CLONE)); then
    printf '%s-clone\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

derive_name() {
  local agent
  local workspace="$2"
  local abs slug full hash prefix suffix budget truncated

  agent=$(agent_label "$1")
  abs=$(abs_path "$workspace")
  slug=$(path_slug "$abs")
  full="${agent}.${slug}"

  if ((${#full} <= MAX_NAME)); then
    printf '%s\n' "$full"
    return
  fi

  hash=$(path_hash "$abs")
  prefix="${agent}."
  suffix=".${hash}"
  budget=$((MAX_NAME - ${#prefix} - ${#suffix}))
  if ((budget < 1)); then
    die "agent name too long to form a valid sandbox name: $agent"
  fi

  truncated="$slug"
  if ((${#truncated} > budget)); then
    truncated="${slug: -budget}"
    truncated="${truncated#.}"
    truncated="${truncated#-}"
  fi
  printf '%s\n' "${prefix}${truncated}${suffix}"
}

select_agent() {
  local choice
  if command -v fzf >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    choice=$(printf '%s\n' "${AGENTS[@]}" | fzf --prompt='agent> ' --height=10) || true
    [[ -n "${choice:-}" ]] || die "no agent selected"
    printf '%s\n' "$choice"
    return
  fi

  local i
  for i in "${!AGENTS[@]}"; do
    printf '%d) %s\n' "$((i + 1))" "${AGENTS[$i]}" >&2
  done
  printf 'agent [1-%d]: ' "${#AGENTS[@]}" >&2
  read -r choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#AGENTS[@]})); then
    printf '%s\n' "${AGENTS[$((choice - 1))]}"
    return
  fi
  if is_agent "$choice"; then
    printf '%s\n' "$choice"
    return
  fi
  die "invalid agent selection: $choice"
}

resolve_agent() {
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    select_agent
  elif is_agent "$arg"; then
    printf '%s\n' "$arg"
  else
    die "unknown agent: $arg (expected: ${AGENTS[*]})"
  fi
}

kit_path() {
  local kit="${SBXA_KIT:-$DEFAULT_KIT}"
  [[ -d "$kit" ]] || die "kit directory not found: $kit"
  printf '%s\n' "$kit"
}

# Parse --clone / --kit flags; remaining args go to POSITIONALS.
# Everything after "--" is collected into AGENT_ARGS for the agent.
parse_run_args() {
  POSITIONALS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clone)
        CLONE=1
        shift
        ;;
      --kit)
        [[ -n "${2:-}" ]] || die "--kit requires a path"
        EXTRA_KITS+=("$2")
        shift 2
        ;;
      --kit=*)
        EXTRA_KITS+=("${1#--kit=}")
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        AGENT_ARGS+=("$@")
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        POSITIONALS+=("$1")
        shift
        ;;
    esac
  done
}

discover_workspace_kits() {
  local ws="$1"
  local d
  [[ -d "$ws/sbx" ]] || return 0
  shopt -s nullglob
  for d in "$ws/sbx"/*; do
    if [[ -d "$d" && -f "$d/spec.yaml" ]]; then
      printf '%s\n' "$d"
    fi
  done
  shopt -u nullglob
}

normalize_kit_ref() {
  local k="$1"
  local dir resolved
  if [[ -d "$k" ]]; then
    resolved=$(cd "$k" && pwd -P) || die "cannot access kit directory: $k"
    printf '%s\n' "$resolved"
  elif [[ -f "$k" ]]; then
    dir=$(cd "$(dirname -- "$k")" && pwd -P) || die "cannot access kit path: $k"
    printf '%s/%s\n' "$dir" "$(basename -- "$k")"
  else
    die "kit not found: $k"
  fi
}

# Resolve create-time kit list: default nix + workspace sbx/* + env + --kit.
collect_kits() {
  local ws="$1"
  local -a kits=()
  local k path seen=""

  kits+=("$(kit_path)")

  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    kits+=("$k")
  done < <(discover_workspace_kits "$ws")

  if [[ -n "${SBXA_EXTRA_KITS:-}" ]]; then
    local -a extra=()
    IFS=':' read -r -a extra <<<"${SBXA_EXTRA_KITS}"
    for k in "${extra[@]}"; do
      [[ -n "$k" ]] || continue
      kits+=("$k")
    done
  fi

  for k in "${EXTRA_KITS[@]}"; do
    kits+=("$k")
  done

  for k in "${kits[@]}"; do
    path=$(normalize_kit_ref "$k")
    case ":$seen:" in
      *":$path:"*) continue ;;
    esac
    seen="${seen}:${path}"
    printf '%s\n' "$path"
  done
}

# sbx --clone only accepts the main working tree of a non-bare repository:
# it rejects linked worktrees ("run from the main repository instead") and
# bare repositories ("not in a Git repository"). Fail early with the reason.
clone_preflight() {
  local path="$1"
  local gitdir common
  gitdir=$(git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) \
    || die "--clone requires a git repository: $path"
  if [[ "$(git -C "$path" rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]; then
    die "--clone needs a working tree; $path is a bare repository (sbx cannot clone it)"
  fi
  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  if [[ "$gitdir" != "$common" ]]; then
    die "--clone is rejected by sbx on linked worktrees; $path belongs to $common. Use the main working tree of a non-bare checkout, or run direct mode (sbxa $AGENT $path)"
  fi
}

# Resolve [agent] [path] positionals into AGENT and WORKSPACE (unresolved path).
resolve_agent_path() {
  if (($# > 2)); then
    die "unexpected arguments: ${*:3}"
  fi
  if [[ -n "${1:-}" ]] && is_agent "$1"; then
    AGENT="$1"
    WORKSPACE="${2:-.}"
  elif [[ -n "${1:-}" && -z "${2:-}" && -d "$1" ]] && ! is_agent "$1"; then
    AGENT=$(select_agent)
    WORKSPACE="$1"
  elif [[ -z "${1:-}" ]]; then
    AGENT=$(select_agent)
    WORKSPACE="."
  else
    AGENT=$(resolve_agent "$1")
    WORKSPACE="${2:-.}"
  fi
}

cmd_ls() {
  sandbox_names | grep -E '^(cursor|claude|gemini)(-clone)?\.' || true
}

cmd_name() {
  resolve_agent_path "$@"
  derive_name "$AGENT" "$WORKSPACE"
}

cmd_fetch() {
  local name path remote
  CLONE=1
  resolve_agent_path "$@"
  name=$(derive_name "$AGENT" "$WORKSPACE")
  path=$(abs_path "$WORKSPACE")
  remote="sandbox-$name"

  name_exists "$name" || die "sandbox not found: $name (create it with: sbxa --clone $AGENT $path)"
  git -C "$path" remote get-url "$remote" >/dev/null 2>&1 \
    || die "remote $remote not found in $path (is the sandbox running? sbx registers it on start)"

  printf 'sbxa: fetching %s\n' "$remote" >&2
  git -C "$path" fetch "$remote"
  git -C "$path" branch -r --list "$remote/*"
}

cmd_rm() {
  local target="${1:-}"
  local name agent

  if [[ -z "$target" ]]; then
    agent=$(select_agent)
    name=$(derive_name "$agent" ".")
  elif [[ "$target" == *.* ]]; then
    name="$target"
  elif is_agent "$target"; then
    name=$(derive_name "$target" ".")
  else
    die "rm expects an agent or exact sandbox name, got: $target"
  fi

  name_exists "$name" || die "sandbox not found: $name"
  sbx rm --force "$name"
}

cmd_run() {
  local agent path name template
  local -a kits=()
  local -a cmd=()
  local k

  resolve_agent_path "$@"
  agent="$AGENT"
  name=$(derive_name "$agent" "$WORKSPACE")
  path=$(abs_path "$WORKSPACE")

  if name_exists "$name"; then
    if ((${#EXTRA_KITS[@]} > 0)) || [[ -n "${SBXA_EXTRA_KITS:-}" ]]; then
      printf 'sbxa: ignoring extra kits on attach (kits only apply at create)\n' >&2
    fi
    printf 'sbxa: attaching %s\n' "$name" >&2
    cmd=(sbx run --name "$name")
    if ((${#AGENT_ARGS[@]} > 0)); then
      cmd+=(-- "${AGENT_ARGS[@]}")
    fi
    exec "${cmd[@]}"
  fi

  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    kits+=("$k")
  done < <(collect_kits "$path")

  template=$(template_for "$agent")
  if ((CLONE)); then
    clone_preflight "$path"
    printf 'sbxa: creating %s (clone mode)\n' "$name" >&2
  else
    printf 'sbxa: creating %s\n' "$name" >&2
  fi
  for k in "${kits[@]}"; do
    printf 'sbxa:   kit %s\n' "$k" >&2
  done

  cmd=(sbx run)
  if ((CLONE)); then
    cmd+=(--clone)
  fi
  cmd+=(--template "$template" --name "$name")
  for k in "${kits[@]}"; do
    cmd+=(--kit "$k")
  done
  cmd+=("$agent" "$path")
  if ((${#AGENT_ARGS[@]} > 0)); then
    cmd+=(-- "${AGENT_ARGS[@]}")
  fi
  exec "${cmd[@]}"
}

main() {
  case "${1:-}" in
    -h | --help | help)
      usage
      ;;
    ls)
      shift
      cmd_ls "$@"
      ;;
    rm)
      shift
      parse_run_args "$@"
      cmd_rm "${POSITIONALS[@]}"
      ;;
    name)
      shift
      parse_run_args "$@"
      cmd_name "${POSITIONALS[@]}"
      ;;
    fetch)
      shift
      parse_run_args "$@"
      cmd_fetch "${POSITIONALS[@]}"
      ;;
    run)
      shift
      parse_run_args "$@"
      cmd_run "${POSITIONALS[@]}"
      ;;
    *)
      parse_run_args "$@"
      cmd_run "${POSITIONALS[@]}"
      ;;
  esac
}

main "$@"
