# sbxa — idempotent create-or-attach for nix-agent sandboxes.
# Packaged via writeShellApplication; @storeKit@ is substituted at build time.

set -euo pipefail

AGENTS=(cursor claude gemini)
MAX_NAME=63
DEFAULT_KIT="@storeKit@"
EXTRA_KITS=()

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
  sbxa [--kit PATH]... [agent] [path]
  sbxa run [--kit PATH]... [agent] [path]
  sbxa name [agent] [path]
  sbxa ls
  sbxa rm [agent|name]

On create, kits are stacked in order:
  1. baked-in nix kit (override with SBXA_KIT)
  2. each $workspace/sbx/*/spec.yaml directory (auto)
  3. each path in SBXA_EXTRA_KITS (colon-separated)
  4. each --kit PATH

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
  # sbx names: letters, numbers, hyphens, underscores, periods, plus
  slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//; s/^\.+//; s/\.+$//')
  if [[ -z "$slug" ]]; then
    slug="workspace"
  fi
  printf '%s\n' "$slug"
}

path_hash() {
  printf '%s' "$1" | sha256sum | cut -c1-8
}

derive_name() {
  local agent="$1"
  local workspace="$2"
  local abs slug full hash prefix suffix budget truncated

  abs=$(abs_path "$workspace")
  slug=$(path_slug "$abs")
  full="${agent}+${slug}"

  if ((${#full} <= MAX_NAME)); then
    printf '%s\n' "$full"
    return
  fi

  hash=$(path_hash "$abs")
  prefix="${agent}+"
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

# Parse --kit flags into EXTRA_KITS; remaining args go to POSITIONALS.
parse_run_args() {
  POSITIONALS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
        POSITIONALS+=("$@")
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

cmd_ls() {
  sandbox_names | grep -E '^(cursor|claude|gemini)\+' || true
}

cmd_name() {
  local agent path
  if [[ -n "${1:-}" ]] && is_agent "$1"; then
    agent="$1"
    path="${2:-.}"
  elif [[ -n "${1:-}" && -z "${2:-}" && -d "$1" ]] && ! is_agent "$1"; then
    agent=$(select_agent)
    path="$1"
  else
    agent=$(resolve_agent "${1:-}")
    path="${2:-.}"
  fi
  derive_name "$agent" "$path"
}

cmd_rm() {
  local target="${1:-}"
  local name agent

  if [[ -z "$target" ]]; then
    agent=$(select_agent)
    name=$(derive_name "$agent" ".")
  elif [[ "$target" == *+* ]]; then
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

  if [[ -n "${1:-}" ]] && is_agent "$1"; then
    agent="$1"
    path="${2:-.}"
  elif [[ -n "${1:-}" && -z "${2:-}" && -d "$1" ]] && ! is_agent "$1"; then
    agent=$(select_agent)
    path="$1"
  elif [[ -z "${1:-}" ]]; then
    agent=$(select_agent)
    path="."
  else
    die "unexpected arguments: $*"
  fi

  name=$(derive_name "$agent" "$path")
  path=$(abs_path "$path")

  if name_exists "$name"; then
    if ((${#EXTRA_KITS[@]} > 0)) || [[ -n "${SBXA_EXTRA_KITS:-}" ]]; then
      printf 'sbxa: ignoring extra kits on attach (kits only apply at create)\n' >&2
    fi
    printf 'sbxa: attaching %s\n' "$name" >&2
    exec sbx run --name "$name"
  fi

  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    kits+=("$k")
  done < <(collect_kits "$path")

  template=$(template_for "$agent")
  printf 'sbxa: creating %s\n' "$name" >&2
  for k in "${kits[@]}"; do
    printf 'sbxa:   kit %s\n' "$k" >&2
  done

  cmd=(sbx run --template "$template" --name "$name")
  for k in "${kits[@]}"; do
    cmd+=(--kit "$k")
  done
  cmd+=("$agent" "$path")
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
      cmd_rm "$@"
      ;;
    name)
      shift
      cmd_name "$@"
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
