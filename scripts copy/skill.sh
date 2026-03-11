#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SKILLS_DIR="$ROOT/.agent/skills"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
GLOBAL_SKILLS_DIR="$CODEX_HOME_DIR/skills"
INSTALLER_DIR="$GLOBAL_SKILLS_DIR/.system/skill-installer/scripts"
INSTALL_FROM_GITHUB="$INSTALLER_DIR/install-skill-from-github.py"
LIST_CURATED="$INSTALLER_DIR/list-skills.py"

usage() {
  cat <<'EOF'
Usage:
  scripts/skill.sh search <query>
  scripts/skill.sh ensure <query-or-skill-name>
  scripts/skill.sh install <skill-name|owner/repo@skill|github-url|skills.sh-url>
  scripts/skill.sh list-local
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_file() {
  [[ -f "$1" ]] || die "Missing required file: $1"
}

local_skill_entries() {
  local search_root="$1"
  [[ -d "$search_root" ]] || return 0
  find "$search_root" -type f -name SKILL.md -print | while read -r skill_md; do
    local skill_dir
    skill_dir="$(dirname "$skill_md")"
    printf '%s\t%s\n' "$(basename "$skill_dir")" "$skill_dir"
  done
}

local_exact_match() {
  local name="$1"
  local_skill_entries "$REPO_SKILLS_DIR" | awk -F '\t' -v q="$name" '$1 == q { print $2 }'
  local_skill_entries "$GLOBAL_SKILLS_DIR" | awk -F '\t' -v q="$name" '$1 == q { print $2 }'
}

search_local() {
  local query="$1"
  local_skill_entries "$REPO_SKILLS_DIR" | awk -F '\t' -v q="$query" 'tolower($1) ~ tolower(q) { print "repo\t" $1 "\t" $2 }'
  local_skill_entries "$GLOBAL_SKILLS_DIR" | awk -F '\t' -v q="$query" 'tolower($1) ~ tolower(q) { print "global\t" $1 "\t" $2 }'
}

curated_exact_match() {
  local query="$1"
  require_file "$LIST_CURATED"
  python3 "$LIST_CURATED" --format json 2>/dev/null | python3 - "$query" 2>/dev/null <<'PY'
import json
import sys

query = sys.argv[1]
for item in json.load(sys.stdin):
    if item["name"] == query:
        print(item["name"])
        break
PY
}

remote_specs() {
  local query="$1"
  require_cmd npx
  require_cmd perl
  npx --yes skills find "$query" 2>/dev/null \
    | perl -pe 's/\e\[[0-9;]*[[:alpha:]]//g' \
    | grep -Eo '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[A-Za-z0-9._-]+' \
    | grep -v '^owner/repo@skill$' \
    | awk '!seen[$0]++'
}

rank_remote_specs() {
  local query="$1"
  python3 -c '
import re
import sys

TRUSTED_REPOS = {
    "vercel-labs/skills": 0,
    "openai/skills": 1,
    "wshobson/agents": 2,
    "composiohq/awesome-claude-skills": 3,
}

query = sys.argv[1].strip().lower()
query_norm = re.sub(r"[^a-z0-9._-]+", "-", query).strip("-")
scored = []

for index, raw_line in enumerate(sys.stdin):
    spec = raw_line.strip()
    if not spec or "@" not in spec or "/" not in spec:
        continue
    repo, skill = spec.split("@", 1)
    repo_l = repo.lower()
    skill_l = skill.lower()

    score = 0
    if query_norm and skill_l == query_norm:
        score += 1000
    elif query and query in skill_l:
        score += 200

    if repo_l in TRUSTED_REPOS:
        score += 400 - (TRUSTED_REPOS[repo_l] * 25)
    elif repo_l.endswith("/skills"):
        score += 100

    score += max(0, 50 - index)
    scored.append((score, spec))

for _, spec in sorted(scored, key=lambda item: (-item[0], item[1])):
    print(spec)
' "$query"
}

choose_remote_spec() {
  local query="$1"
  python3 -c '
import re
import sys

TRUSTED_REPOS = {
    "vercel-labs/skills": 0,
    "openai/skills": 1,
    "wshobson/agents": 2,
    "composiohq/awesome-claude-skills": 3,
}

query = sys.argv[1].strip().lower()
query_norm = re.sub(r"[^a-z0-9._-]+", "-", query).strip("-")
specs = [line.strip() for line in sys.stdin if line.strip()]

exact = []
for spec in specs:
    if "@" not in spec or "/" not in spec:
        continue
    repo, skill = spec.split("@", 1)
    repo_l = repo.lower()
    skill_l = skill.lower()
    if skill_l != query_norm:
        continue
    exact.append((TRUSTED_REPOS.get(repo_l, 999), spec))

if not exact:
    sys.exit(0)

exact.sort(key=lambda item: (item[0], item[1]))
best_rank, best_spec = exact[0]
if best_rank < 999:
    print(best_spec)
elif len(exact) == 1:
    print(best_spec)
' "$query"
}

promote_global_to_shared() {
  local skill_name="$1"
  local global_path="$GLOBAL_SKILLS_DIR/$skill_name"
  local shared_path="$REPO_SKILLS_DIR/$skill_name"

  if [[ ! -d "$global_path" || ! -f "$global_path/SKILL.md" || -e "$shared_path" ]]; then
    return 0
  fi

  mkdir -p "$REPO_SKILLS_DIR"
  cp -R "$global_path" "$shared_path"
  python3 "$ROOT/scripts/generate_skill_index.py" >/dev/null
  echo "Promoted to shared repo skills: $shared_path"
}

install_curated() {
  local name="$1"
  require_file "$INSTALL_FROM_GITHUB"

  if [[ ! -d "$REPO_SKILLS_DIR/$name" ]]; then
    python3 "$INSTALL_FROM_GITHUB" \
      --repo openai/skills \
      --path "skills/.curated/$name" \
      --dest "$REPO_SKILLS_DIR"
  fi

  if [[ ! -d "$GLOBAL_SKILLS_DIR/$name" ]]; then
    python3 "$INSTALL_FROM_GITHUB" \
      --repo openai/skills \
      --path "skills/.curated/$name" \
      --dest "$GLOBAL_SKILLS_DIR"
  fi

  python3 "$ROOT/scripts/generate_skill_index.py" >/dev/null
  echo "Installed curated skill: $name"
}

install_github_url() {
  local url="$1"
  local trimmed_url
  local skill_name
  require_file "$INSTALL_FROM_GITHUB"

  trimmed_url="${url%/}"
  skill_name="${trimmed_url##*/}"

  if [[ ! -d "$REPO_SKILLS_DIR/$skill_name" ]]; then
    python3 "$INSTALL_FROM_GITHUB" --url "$url" --dest "$REPO_SKILLS_DIR"
  fi

  if [[ ! -d "$GLOBAL_SKILLS_DIR/$skill_name" ]]; then
    python3 "$INSTALL_FROM_GITHUB" --url "$url" --dest "$GLOBAL_SKILLS_DIR"
  fi

  python3 "$ROOT/scripts/generate_skill_index.py" >/dev/null
  echo "Installed GitHub skill from: $url"
}

install_skills_sh_url() {
  local url="$1"
  local parsed
  local owner
  local repo
  local skill_name

  parsed="$(python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse

url = urlparse(sys.argv[1])
parts = [part for part in url.path.split("/") if part]
if url.netloc != "skills.sh" or len(parts) != 3:
    sys.exit(1)
print("\t".join(parts))
PY
)" || die "Unsupported skills.sh URL: $url"

  owner="${parsed%%$'\t'*}"
  parsed="${parsed#*$'\t'}"
  repo="${parsed%%$'\t'*}"
  skill_name="${parsed##*$'\t'}"

  if [[ ! -d "$REPO_SKILLS_DIR/$skill_name" ]]; then
    python3 "$INSTALL_FROM_GITHUB" \
      --repo "$owner/$repo" \
      --path "skills/$skill_name" \
      --dest "$REPO_SKILLS_DIR"
  fi

  if [[ ! -d "$GLOBAL_SKILLS_DIR/$skill_name" ]]; then
    require_cmd npx
    npx --yes skills add "https://github.com/$owner/$repo" --skill "$skill_name" -g -y
  fi

  promote_global_to_shared "$skill_name"
  python3 "$ROOT/scripts/generate_skill_index.py" >/dev/null
  echo "Installed skills.sh skill: $url"
}

install_remote_spec() {
  local spec="$1"
  require_cmd npx
  npx --yes skills add "$spec" -g -y

  local skill_name
  skill_name="${spec##*@}"
  promote_global_to_shared "$skill_name"
  echo "Installed remote skill: $spec"
}

search_command() {
  local query="$1"
  echo "[local]"
  search_local "$query" || true
  echo
  echo "[curated exact]"
  curated_exact_match "$query" || true
  echo
  echo "[remote]"
  remote_specs "$query" | rank_remote_specs "$query" || true
}

ensure_command() {
  local query="$1"

  local existing
  existing="$(local_exact_match "$query" || true)"
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return 0
  fi

  local curated
  curated="$(curated_exact_match "$query" || true)"
  if [[ -n "$curated" ]]; then
    install_curated "$curated"
    return 0
  fi

  mapfile -t specs < <(remote_specs "$query" | rank_remote_specs "$query" || true)
  if [[ "${#specs[@]}" -eq 0 ]]; then
    die "No local, curated, or remote skill candidates found for '$query'."
  fi

  local selected
  selected="$(printf '%s\n' "${specs[@]}" | choose_remote_spec "$query" || true)"
  if [[ -n "$selected" ]]; then
    install_remote_spec "$selected"
    return 0
  fi

  if [[ "${#specs[@]}" -gt 1 ]]; then
    printf '%s\n' "${specs[@]}"
    die "Multiple remote skill candidates found for '$query'. Pick one explicitly."
  fi

  install_remote_spec "${specs[0]}"
}

install_command() {
  local target="$1"

  if [[ "$target" =~ ^https://skills\.sh/ ]]; then
    install_skills_sh_url "$target"
    return 0
  fi

  if [[ "$target" =~ ^https://github\.com/ ]]; then
    install_github_url "$target"
    return 0
  fi

  if [[ "$target" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]]; then
    install_remote_spec "$target"
    return 0
  fi

  local curated
  curated="$(curated_exact_match "$target" || true)"
  if [[ -n "$curated" ]]; then
    install_curated "$curated"
    return 0
  fi

  ensure_command "$target"
}

list_local_command() {
  echo "[repo]"
  local_skill_entries "$REPO_SKILLS_DIR" | awk -F '\t' '{ print $1 "\t" $2 }'
  echo
  echo "[global]"
  local_skill_entries "$GLOBAL_SKILLS_DIR" | awk -F '\t' '{ print $1 "\t" $2 }'
}

main() {
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }

  case "$1" in
    search)
      [[ $# -eq 2 ]] || die "search requires exactly one query."
      search_command "$2"
      ;;
    ensure)
      [[ $# -eq 2 ]] || die "ensure requires exactly one query."
      ensure_command "$2"
      ;;
    install)
      [[ $# -eq 2 ]] || die "install requires exactly one target."
      install_command "$2"
      ;;
    list-local)
      [[ $# -eq 1 ]] || die "list-local takes no arguments."
      list_local_command
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
