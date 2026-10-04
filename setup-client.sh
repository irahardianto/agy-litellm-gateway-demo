#!/usr/bin/env bash
# =============================================================================
# Antigravity Enterprise Gateway — one-time client setup (Linux / macOS)
# =============================================================================
# Run this ONCE per machine (and again only after the model list changes).
# After that, every new terminal — bash, zsh, fish, tmux, IDE terminals — sees
# the full gateway model list. No `source gateway.env` needed, ever.
#
# Usage:
#   ./setup-client.sh [options]          (run as your normal user, NOT with sudo)
#
# Options:
#   -n, --dry-run               Show what would change; write nothing
#   -s, --status                Show the current client configuration and exit
#   -u, --uninstall             Remove the shell hooks / env files this script made
#       --skip-admin-settings   Don't install admin_settings.json (no sudo needed)
#   -h, --help                  Show this help
#
# What it does:
#   1. Installs admin_settings.json system-wide (mode 644). This is the only step
#      that needs root; sudo is invoked for that single step and may prompt you.
#   2. Writes ~/.config/antigravity/gateway-models.sh exporting
#      AGY_LLM_GATEWAY_MODELS. This is the ONLY variable agy needs; it contains
#      model IDs only, no API key. URL/key/headers come from admin_settings.json.
#   3. Adds one clearly-marked, idempotent block to your shell startup files
#      (zsh: ~/.zshenv, bash: ~/.bashrc, fish: conf.d) and, on systemd Linux,
#      ~/.config/environment.d so GUI-launched apps see it too.
#   4. Verifies that a fresh shell of each kind actually sees the variable.
#
# Safety: every existing file is backed up (<file>.agy-backup-<timestamp>) before
# the first change; re-running makes no changes if nothing differs; model IDs are
# validated before they are written into any startup file.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

info() { echo -e "${GREEN}✓${NC} $*"; }
note() { echo -e "${BLUE}•${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*" >&2; }
die()  { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }
usage() { sed -n '3,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE="install"
DRY_RUN=false
SKIP_ADMIN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)            DRY_RUN=true; shift ;;
    -s|--status)             MODE="status"; shift ;;
    -u|--uninstall)          MODE="uninstall"; shift ;;
    --skip-admin-settings)   SKIP_ADMIN=true; shift ;;
    -h|--help)               usage; exit 0 ;;
    *)                       usage; die "Unknown argument: $1" ;;
  esac
done

# --- Environment checks -------------------------------------------------------
[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "Run this as your normal user, not root/sudo. It calls sudo itself, only for the one /etc step.
       (Running as root would configure root's home instead of yours.)"
[[ -n "${HOME:-}" && -d "$HOME" ]] || die "\$HOME is not set to a valid directory."

OS="$(uname -s)"
case "$OS" in
  Linux)  ADMIN_DEST_DEFAULT="/etc/antigravity/admin_settings.json" ;;
  Darwin) ADMIN_DEST_DEFAULT="/Library/Application Support/Antigravity/admin_settings.json" ;;
  *)      die "Unsupported OS '$OS'. On Windows use the PowerShell snippet in README.md." ;;
esac
# AGY_ADMIN_SETTINGS_DEST is a test hook; real users never need it.
ADMIN_DEST="${AGY_ADMIN_SETTINGS_DEST:-$ADMIN_DEST_DEFAULT}"

ADMIN_SRC="${SCRIPT_DIR}/admin_settings.json"
ENV_SRC="${SCRIPT_DIR}/gateway.env"

CONF_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
ENV_DIR="${CONF_HOME}/antigravity"
ENV_FILE="${ENV_DIR}/gateway-models.sh"
SYSTEMD_ENV_FILE="${CONF_HOME}/environment.d/50-antigravity-gateway.conf"
FISH_FILE="${CONF_HOME}/fish/conf.d/antigravity-gateway.fish"

BEGIN_MARK="# >>> antigravity gateway (managed by setup-client.sh) >>>"
END_MARK="# <<< antigravity gateway <<<"
TS="$(date +%Y%m%d%H%M%S)"

MODELS=""
ADMIN_PENDING=false
CHANGED=false

# --- Helpers ------------------------------------------------------------------
read_models() {
  [[ -r "$ENV_SRC" ]] || die "Cannot read ${ENV_SRC}.
       Run ./deploy.sh first (it generates it), or copy gateway.env from your gateway admin."
  local line
  line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?AGY_LLM_GATEWAY_MODELS=' "$ENV_SRC" | tail -n1 || true)"
  [[ -n "$line" ]] || die "No AGY_LLM_GATEWAY_MODELS line found in ${ENV_SRC}."
  line="${line#*=}"
  line="${line//$'\r'/}"
  line="${line#\"}"; line="${line%\"}"
  line="${line#\'}"; line="${line%\'}"
  [[ -n "$line" ]] || die "AGY_LLM_GATEWAY_MODELS in ${ENV_SRC} is empty."
  # Model IDs end up inside shell startup files: refuse anything unexpected.
  [[ "$line" =~ ^[A-Za-z0-9._@:,-]+$ ]] || die "AGY_LLM_GATEWAY_MODELS contains unexpected characters; refusing to write it into shell startup files."
  MODELS="$line"
}

backup_once() {  # backup_once <file>
  local f="$1"
  if [[ -e "$f" && ! -e "${f}.agy-backup-${TS}" ]]; then
    cp -p "$f" "${f}.agy-backup-${TS}"
    note "Backed up ${f} -> ${f}.agy-backup-${TS}"
  fi
}

# Write <content> to <file> only if it differs. Writes through (not over) the
# path so symlinked dotfiles (stow, chezmoi, ...) keep working.
write_if_changed() {  # write_if_changed <file> <content> <label>
  local f="$1" content="$2" label="$3"
  if [[ -f "$f" ]] && [[ "$(cat "$f")" == "$content" ]]; then
    info "${label}: already up to date (${f})"
    return 0
  fi
  if $DRY_RUN; then note "[dry-run] would write ${label}: ${f}"; return 0; fi
  mkdir -p "$(dirname "$f")"
  backup_once "$f"
  printf '%s\n' "$content" > "$f"
  info "${label}: wrote ${f}"
  CHANGED=true
}

shell_block() {
  cat <<EOF
${BEGIN_MARK}
if [ -r "\${XDG_CONFIG_HOME:-\$HOME/.config}/antigravity/gateway-models.sh" ]; then
  . "\${XDG_CONFIG_HOME:-\$HOME/.config}/antigravity/gateway-models.sh"
fi
${END_MARK}
EOF
}

has_block() { [[ -f "$1" ]] && grep -qF "$BEGIN_MARK" "$1"; }

upsert_block() {  # upsert_block <file> <label>
  local f="$1" label="$2" block cur tmp
  block="$(shell_block)"
  if has_block "$f"; then
    cur="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{p=1} p{print} $0==e{p=0}' "$f")"
    if [[ "$cur" == "$block" ]]; then
      info "${label}: hook already present (${f})"
      return 0
    fi
    if $DRY_RUN; then note "[dry-run] would update hook in ${f}"; return 0; fi
    backup_once "$f"
    tmp="$(mktemp)"
    BLOCK="$block" awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
      '$0==b{print ENVIRON["BLOCK"]; skip=1; next} $0==e{skip=0; next} !skip{print}' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    info "${label}: updated hook in ${f}"
    CHANGED=true
    return 0
  fi
  if $DRY_RUN; then note "[dry-run] would append hook to ${f}"; return 0; fi
  backup_once "$f"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  # Ensure the file ends with a newline before appending.
  if [[ -s "$f" && -n "$(tail -c1 "$f")" ]]; then printf '\n' >> "$f"; fi
  printf '\n%s\n' "$block" >> "$f"
  info "${label}: added hook to ${f}"
  CHANGED=true
}

remove_block() {  # remove_block <file> <label>
  local f="$1" label="$2" tmp
  has_block "$f" || return 0
  if $DRY_RUN; then note "[dry-run] would remove hook from ${f}"; return 0; fi
  backup_once "$f"
  tmp="$(mktemp)"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b { held=0; skip=1; next }
    skip  { if ($0==e) skip=0; next }
    held  { print ""; held=0 }
    $0=="" { held=1; next }
    { print }
    END   { if (held) print "" }' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
  info "${label}: removed hook from ${f}"
}

login_shell() { basename "${SHELL:-}"; }

# Which shell startup files to hook on this machine.
hook_targets() {  # prints "<label>|<file>" lines
  local ls; ls="$(login_shell)"
  if command -v zsh >/dev/null 2>&1 || [[ -f "$HOME/.zshenv" || -f "$HOME/.zshrc" || "$ls" == "zsh" ]]; then
    echo "zsh|$HOME/.zshenv"
  fi
  if [[ -f "$HOME/.bashrc" || "$ls" == "bash" ]]; then
    echo "bash|$HOME/.bashrc"
  fi
  if [[ "$OS" == "Darwin" && -f "$HOME/.bash_profile" ]]; then
    echo "bash (macOS login)|$HOME/.bash_profile"
  fi
}

# --- Step 1: admin_settings.json ---------------------------------------------
install_admin_settings() {
  if $SKIP_ADMIN; then note "Skipping admin_settings.json (--skip-admin-settings)."; return 0; fi
  [[ -r "$ADMIN_SRC" ]] || die "Cannot read ${ADMIN_SRC}. Run ./deploy.sh first, or copy it from your gateway admin."
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$ADMIN_SRC" >/dev/null 2>&1 || die "${ADMIN_SRC} is not valid JSON; refusing to install it."
  fi

  if [[ -f "$ADMIN_DEST" ]] && cmp -s "$ADMIN_SRC" "$ADMIN_DEST"; then
    info "admin_settings.json: already installed and up to date (${ADMIN_DEST})"
    return 0
  fi

  local dir; dir="$(dirname "$ADMIN_DEST")"
  local priv=()
  if { [[ -d "$dir" && -w "$dir" ]] || { [[ ! -e "$dir" ]] && [[ -w "$(dirname "$dir")" ]]; }; } \
     && { [[ ! -e "$ADMIN_DEST" ]] || [[ -w "$ADMIN_DEST" ]]; }; then
    priv=()
  elif command -v sudo >/dev/null 2>&1; then
    priv=(sudo)
  else
    warn "Need root to write ${ADMIN_DEST}, but sudo is not available."
    ADMIN_PENDING=true
    return 0
  fi

  if $DRY_RUN; then
    note "[dry-run] would run: ${priv[*]:-} install -m 644 admin_settings.json ${ADMIN_DEST}"
    return 0
  fi

  if [[ ${#priv[@]} -gt 0 ]]; then note "Installing ${ADMIN_DEST} (sudo may ask for your password)..."; fi
  if ! {
    { [[ ! -e "$ADMIN_DEST" ]] || ${priv[@]+"${priv[@]}"} cp -p "$ADMIN_DEST" "${ADMIN_DEST}.agy-backup-${TS}"; } \
      && ${priv[@]+"${priv[@]}"} install -d -m 755 "$dir" \
      && ${priv[@]+"${priv[@]}"} install -m 644 "$ADMIN_SRC" "$ADMIN_DEST"
  }; then
    warn "Could not install ${ADMIN_DEST}."
    ADMIN_PENDING=true
    return 0
  fi
  info "admin_settings.json: installed ${ADMIN_DEST} (mode 644)"
  CHANGED=true
}

# --- Step 2-3: env file + shell hooks ----------------------------------------
install_env_and_hooks() {
  local env_content
  env_content="# Managed by setup-client.sh -- do not edit; re-run ./setup-client.sh to update.
# AGY_LLM_GATEWAY_MODELS is the only variable agy needs (model IDs, not secret).
# URL / API key / headers come from admin_settings.json.
export AGY_LLM_GATEWAY_MODELS=\"${MODELS}\""
  write_if_changed "$ENV_FILE" "$env_content" "model list"

  local label file
  while IFS='|' read -r label file; do
    [[ -n "$file" ]] || continue
    upsert_block "$file" "$label"
  done < <(hook_targets)

  if command -v fish >/dev/null 2>&1 || [[ -d "${CONF_HOME}/fish" ]]; then
    write_if_changed "$FISH_FILE" "# Managed by setup-client.sh
set -gx AGY_LLM_GATEWAY_MODELS \"${MODELS}\"" "fish"
  fi

  if [[ "$OS" == "Linux" && -d /run/systemd/system ]]; then
    write_if_changed "$SYSTEMD_ENV_FILE" "# Managed by setup-client.sh (read by systemd --user at login)
AGY_LLM_GATEWAY_MODELS=${MODELS}" "systemd user environment"
    if ! $DRY_RUN && [[ -z "${AGY_SETUP_TEST:-}" ]] && command -v systemctl >/dev/null 2>&1; then
      # Best effort: makes apps launched from your current desktop session see it now.
      systemctl --user set-environment "AGY_LLM_GATEWAY_MODELS=${MODELS}" >/dev/null 2>&1 || true
    fi
  fi
}

# --- Verification -------------------------------------------------------------
# Spawn a fresh shell with the variable removed and report what it sees.
probe_shell() {  # probe_shell <label> <cmd...>
  local label="$1"; shift
  local out
  out="$(env -u AGY_LLM_GATEWAY_MODELS "$@" 2>/dev/null | sed -n 's/.*__AGY__\(.*\)__AGY__.*/\1/p' | head -n1 || true)"
  if [[ "$out" == "$MODELS" ]]; then
    info "fresh ${label}: sees the model list"
  elif [[ -z "$out" ]]; then
    warn "fresh ${label}: AGY_LLM_GATEWAY_MODELS is NOT set"
    return 1
  else
    warn "fresh ${label}: sees a different model list (${out})"
    return 1
  fi
}

verify_shells() {
  local rc=0
  # zsh -c (non-interactive, reads ~/.zshenv); bash -ic (interactive, reads ~/.bashrc).
  if command -v zsh >/dev/null 2>&1; then
    probe_shell "zsh (non-interactive)" zsh -c 'printf "__AGY__%s__AGY__" "${AGY_LLM_GATEWAY_MODELS:-}"' || rc=1
  fi
  if command -v bash >/dev/null 2>&1 && [[ -f "$HOME/.bashrc" ]]; then
    if command -v setsid >/dev/null 2>&1; then
      # Interactive bash with no controlling TTY gets stopped by job control and
      # would hang forever, so give it its own session, no stdin, and a timeout.
      local -a guard=(setsid)
      command -v timeout >/dev/null 2>&1 && guard=(timeout 20 setsid)
      probe_shell "bash (interactive)" "${guard[@]}" bash -ic 'printf "__AGY__%s__AGY__" "${AGY_LLM_GATEWAY_MODELS:-}"' </dev/null || rc=1
    else
      note "Skipping interactive-bash check (no 'setsid' on this system); open a new terminal to confirm."
    fi
  fi
  if command -v fish >/dev/null 2>&1 && [[ -f "$FISH_FILE" ]]; then
    probe_shell "fish" fish -c 'printf "__AGY__%s__AGY__" "$AGY_LLM_GATEWAY_MODELS"' || rc=1
  fi
  return $rc
}

# agy renames Gemini IDs (gemini-3.8-flash -> gemini-3.8-flash-high/-medium/-low,
# gemini-3.1-pro-preview -> gemini-3.1-pro-low-thinking), so only non-Gemini IDs
# (e.g. Claude) can be checked by exact name. Those are exactly the ones that
# vanish when the variable is missing.
verify_agy() {
  command -v agy >/dev/null 2>&1 || { note "agy not found on PATH; skipping 'agy models' check."; return 0; }
  local listing id checked=0 visible=0
  local -a tmo=()
  command -v timeout >/dev/null 2>&1 && tmo=(timeout 90)
  if command -v zsh >/dev/null 2>&1; then
    listing="$(env -u AGY_LLM_GATEWAY_MODELS ${tmo[@]+"${tmo[@]}"} zsh -c 'agy models' 2>/dev/null </dev/null || true)"
  else
    listing="$(env -u AGY_LLM_GATEWAY_MODELS ${tmo[@]+"${tmo[@]}"} bash -c 'agy models' 2>/dev/null </dev/null || true)"
  fi
  local -a ids
  IFS=',' read -r -a ids <<< "$MODELS"
  for id in "${ids[@]}"; do
    [[ "$id" == gemini-* ]] && continue
    checked=$((checked + 1))
    if printf '%s\n' "$listing" | grep -Eq "^${id//./\\.}[[:space:]]"; then
      visible=$((visible + 1))
    else
      warn "  '${id}' is configured but not shown by 'agy models'"
    fi
  done
  if [[ "$checked" -eq 0 ]]; then
    note "No non-Gemini models configured; nothing extra to verify in 'agy models'."
  elif [[ "$visible" -eq "$checked" ]]; then
    info "agy models (fresh shell, no manual sourcing): all ${checked} partner models visible"
  else
    warn "agy models: only ${visible}/${checked} partner models visible"
    return 1
  fi
}

# --- Modes --------------------------------------------------------------------
do_status() {
  read_models
  echo -e "${BOLD}Antigravity gateway client status${NC}"
  if [[ -f "$ADMIN_DEST" ]]; then
    if [[ -r "$ADMIN_DEST" ]]; then
      if [[ -r "$ADMIN_SRC" ]] && cmp -s "$ADMIN_SRC" "$ADMIN_DEST"; then
        info "admin_settings.json installed, matches local copy (${ADMIN_DEST})"
      else
        warn "admin_settings.json installed but DIFFERS from local copy (${ADMIN_DEST}); re-run ./setup-client.sh"
      fi
    else
      warn "admin_settings.json exists but is not readable by you (${ADMIN_DEST}); agy will silently ignore it"
    fi
  else
    warn "admin_settings.json NOT installed (${ADMIN_DEST})"
  fi
  if [[ -f "$ENV_FILE" ]]; then info "model list file present (${ENV_FILE})"; else warn "model list file missing (${ENV_FILE})"; fi
  local label file
  while IFS='|' read -r label file; do
    [[ -n "$file" ]] || continue
    if has_block "$file"; then info "${label}: hook present in ${file}"; else warn "${label}: no hook in ${file}"; fi
  done < <(hook_targets)
  local rc=0
  verify_shells || rc=1
  verify_agy || rc=1
  return $rc
}

do_uninstall() {
  local label file f
  while IFS='|' read -r label file; do
    [[ -n "$file" ]] || continue
    remove_block "$file" "$label"
  done < <(hook_targets)
  for f in "$ENV_FILE" "$FISH_FILE" "$SYSTEMD_ENV_FILE"; do
    if [[ -f "$f" ]]; then
      if $DRY_RUN; then note "[dry-run] would remove ${f}"; else rm -f "$f"; info "removed ${f}"; fi
    fi
  done
  if ! $DRY_RUN && [[ -z "${AGY_SETUP_TEST:-}" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user unset-environment AGY_LLM_GATEWAY_MODELS >/dev/null 2>&1 || true
  fi
  note "Left ${ADMIN_DEST} in place (system file). To remove it too:  sudo rm '${ADMIN_DEST}'"
  note "Open a new terminal for the change to take effect."
}

do_install() {
  read_models
  echo -e "${BOLD}Setting up Antigravity gateway client${NC}  (models: ${MODELS})"
  if $DRY_RUN; then note "Dry run: nothing will be written."; fi
  install_admin_settings
  install_env_and_hooks
  if $DRY_RUN; then return 0; fi
  echo
  local rc=0
  verify_shells || rc=1
  verify_agy || rc=1
  echo
  if $ADMIN_PENDING; then
    warn "admin_settings.json was NOT installed. Run this yourself, then re-run ./setup-client.sh --status:"
    echo "    sudo install -d -m 755 \"$(dirname "$ADMIN_DEST")\" && sudo install -m 644 \"${ADMIN_SRC}\" \"${ADMIN_DEST}\""
    return 2
  fi
  if [[ $rc -ne 0 ]]; then
    warn "Setup finished, but some checks above failed. Run ./setup-client.sh --status for details."
    return 1
  fi
  echo -e "${GREEN}${BOLD}Done. One-time setup complete.${NC}"
  note "Already-open terminals keep their old environment: open a new one, or run:  exec \"\$SHELL\""
  note "After the model list changes (deploy.sh --sync-models), re-run ./setup-client.sh."
}

case "$MODE" in
  install)   do_install ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
esac
