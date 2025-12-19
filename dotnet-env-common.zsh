#!/usr/bin/env zsh

# Shared helpers for switching between toolchain environments.
# NOTE: This file is sourced into your interactive shell.
# Avoid setting global shell options here (e.g., `set -u`), because it can break prompt tooling.

__dotnetenv_die() {
  print -r -- "use-dotnet-env: $*" >&2
  return 1
}

__dotnetenv_warn() {
  print -r -- "use-dotnet-env: $*" >&2
}

__dotnetenv_usage() {
  cat <<'EOF'
Usage:
  use-dotnet9 [--no-select-xcode] [--no-cleanup] [--no-workload-restore]
  use-dotnet10 [--no-select-xcode] [--no-cleanup] [--no-workload-restore]

  (If you don't have those functions yet, define them in ~/.zshrc or ~/.zprofile.)

  Example:
    export DOTNET_ENV_SWITCHER_DIR="/path/to/dotnet-env-switcher"
    use-dotnet9()  { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet9.zsh"  "$@"; }
    use-dotnet10() { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet10.zsh" "$@"; }

What it does:
  - Sets JAVA_HOME to JDK 17 (dotnet9) or JDK 21 (dotnet10) via /usr/libexec/java_home
  - Prepends $JAVA_HOME/bin to PATH
  - Sets DEVELOPER_DIR for the matching Xcode.app
  - Runs: sudo xcode-select -s "$DEVELOPER_DIR"  (system-wide) by default
    - Use --no-select-xcode to skip the system-wide change
  - By default performs a repo cleanup in the current directory:
      - Deletes all '*.csproj.user' files
      - Runs 'dotnet clean' on the first '*.sln' in the current directory (if any)
      - Runs 'dotnet workload restore' on the first '*.sln' in the current directory (if any)
        - If workloads are installed system-wide and permissions are inadequate, it will retry using sudo.
      - Deletes all 'bin' and 'obj' folders recursively (skipping .git/.vs/node_modules)

Configuration (optional):
  export DOTNET9_XCODE_APP="/Applications/Xcode_16.4.app"
  export DOTNET10_XCODE_APP="/Applications/Xcode_26.1.app"   # or your actual path

Notes:
  - If you run the script as an executable (not sourced), exports will NOT persist.
  - VS Code's ".NET MAUI" launcher usually does NOT inherit your terminal's DEVELOPER_DIR.
  - Default behavior switches Xcode system-wide (recommended for VS Code).
      - Or start VS Code from that same terminal after running use-dotnet9/use-dotnet10.
EOF
}

__dotnetenv_dotnet_workload_restore_sln() {
  local root_dir="$1"
  local sln

  if [[ ! -d "$root_dir" ]]; then
    __dotnetenv_die "dotnet-workload-restore: not a directory: $root_dir"
    return 1
  fi

  # Only look in the current directory (not recursive) to match the common "repo root" workflow.
  sln="$(find "$root_dir" -maxdepth 1 -type f -name '*.sln' -print | sort | head -n 1)"
  if [[ -z "${sln:-}" ]]; then
    __dotnetenv_warn "No .sln found in '$root_dir' (skipping dotnet workload restore)."
    return 0
  fi

  print -r -- ""
  print -r -- "Running: dotnet workload restore $(basename -- "$sln")"

  # Try without sudo first (works for user-local workload installs).
  local output
  output="$(dotnet workload restore "$sln" 2>&1)" || {
    print -r -- "$output" >&2

    # If workloads are installed system-wide, dotnet may require elevated privileges.
    if print -r -- "$output" | grep -qiE 'Inadequate permissions|elevated privileges'; then
      __dotnetenv_warn "dotnet workload restore needs elevated privileges; retrying with sudo"
      sudo dotnet workload restore "$sln"
      return $?
    fi

    return 1
  }

  # Print the successful output (kept in case it did real work).
  print -r -- "$output"
}

__dotnetenv_purge_user_files() {
  local root_dir="$1"
  local removed=0

  if [[ -z "${root_dir:-}" ]]; then
    __dotnetenv_die "purge-user-files: root directory is empty"
    return 1
  fi

  if [[ ! -d "$root_dir" ]]; then
    __dotnetenv_die "purge-user-files: not a directory: $root_dir"
    return 1
  fi

  print -r -- ""
  print -r -- "Purging '*.csproj.user' files under: $root_dir"

  # Exclude .git to avoid deleting any repo internals.
  while IFS= read -r -d '' file; do
    rm -f -- "$file" && (( removed++ ))
  done < <(find "$root_dir" -type f -name '*.csproj.user' -not -path '*/.git/*' -print0 2>/dev/null)

  print -r -- "Removed $removed file(s)."
}

__dotnetenv_dotnet_clean_sln() {
  local root_dir="$1"
  local sln

  if [[ ! -d "$root_dir" ]]; then
    __dotnetenv_die "dotnet-clean: not a directory: $root_dir"
    return 1
  fi

  # Only look in the current directory (not recursive) to match the common "repo root" workflow.
  sln="$(find "$root_dir" -maxdepth 1 -type f -name '*.sln' -print | sort | head -n 1)"
  if [[ -z "${sln:-}" ]]; then
    __dotnetenv_warn "No .sln found in '$root_dir' (skipping dotnet clean)."
    return 0
  fi

  print -r -- ""
  print -r -- "Running: dotnet clean $(basename -- "$sln")"
  dotnet clean "$sln" -v minimal
}

__dotnetenv_delete_bin_obj() {
  local root_dir="$1"
  local removed=0

  if [[ ! -d "$root_dir" ]]; then
    __dotnetenv_die "delete-bin-obj: not a directory: $root_dir"
    return 1
  fi

  print -r -- ""
  print -r -- "Deleting 'bin' and 'obj' folders under: $root_dir"

  while IFS= read -r -d '' dir; do
    rm -rf -- "$dir" && (( removed++ ))
  done < <(
    find "$root_dir" \
      \( -path '*/.git/*' -o -path '*/.vs/*' -o -path '*/.idea/*' -o -path '*/node_modules/*' \) -prune -o \
      \( -type d \( -name bin -o -name obj \) -print0 \) 2>/dev/null
  )

  print -r -- "Removed $removed folder(s)."
}

__dotnetenv_repo_cleanup() {
  local root_dir="$1"

  __dotnetenv_purge_user_files "$root_dir" || return 1
  __dotnetenv_dotnet_clean_sln "$root_dir" || return 1
  __dotnetenv_dotnet_workload_restore_sln "$root_dir" || return 1
  __dotnetenv_delete_bin_obj "$root_dir" || return 1
}

__dotnetenv_pick_java_home() {
  local java_version="$1"
  local jh
  if ! jh="$(/usr/libexec/java_home -v "$java_version" 2>/dev/null)"; then
    __dotnetenv_die "Could not locate JDK $java_version via /usr/libexec/java_home -v $java_version"
    return 1
  fi

  export JAVA_HOME="$jh"

  # Ensure JAVA_HOME/bin is first.
  if [[ -n "${JAVA_HOME:-}" ]]; then
    case ":$PATH:" in
      *":$JAVA_HOME/bin:"*) :;;
      *) export PATH="$JAVA_HOME/bin:$PATH";;
    esac
  fi
}

__dotnetenv_pick_xcode_dir() {
  local xcode_app="$1"
  local developer_dir

  if [[ -z "$xcode_app" ]]; then
    __dotnetenv_die "Xcode app path is empty"
    return 1
  fi
  if [[ ! -d "$xcode_app" ]]; then
    __dotnetenv_die "Xcode app not found: $xcode_app"
    return 1
  fi

  developer_dir="$xcode_app/Contents/Developer"
  if [[ ! -d "$developer_dir" ]]; then
    __dotnetenv_die "Developer dir not found: $developer_dir"
    return 1
  fi

  export DEVELOPER_DIR="$developer_dir"
}

__dotnetenv_maybe_xcode_select() {
  local do_select="$1"

  if [[ "$do_select" != "1" ]]; then
    return 0
  fi

  if [[ -z "${DEVELOPER_DIR:-}" || ! -d "${DEVELOPER_DIR:-}" ]]; then
    __dotnetenv_die "DEVELOPER_DIR is not set to a valid directory; cannot xcode-select"
    return 1
  fi

  __dotnetenv_warn "Running: sudo xcode-select -s '$DEVELOPER_DIR'"
  sudo xcode-select -s "$DEVELOPER_DIR"
}

__dotnetenv_print_status() {
  print -r -- ""
  print -r -- "Toolchain status:"
  print -r -- "  JAVA_HOME     = ${JAVA_HOME:-<unset>}"
  print -r -- "  DEVELOPER_DIR = ${DEVELOPER_DIR:-<unset>}"

  if command -v java >/dev/null 2>&1; then
    print -r -- ""
    print -r -- "java -version:"
    java -version 2>&1 | sed -n '1,3p'
  fi

  if command -v xcodebuild >/dev/null 2>&1; then
    print -r -- ""
    print -r -- "xcodebuild -version:"
    xcodebuild -version 2>/dev/null | sed -n '1,2p'
  fi

  if command -v dotnet >/dev/null 2>&1; then
    print -r -- ""
    print -r -- "dotnet --version:"
    dotnet --version 2>/dev/null | sed -n '1p'
  fi
}

__dotnetenv_apply() {
  local mode="$1"           # dotnet9 | dotnet10
  local select_xcode="$2"   # 0 | 1

  if [[ "$mode" != "dotnet9" && "$mode" != "dotnet10" ]]; then
    __dotnetenv_die "Unknown mode: $mode"
    return 1
  fi

  if [[ "$mode" == "dotnet9" ]]; then
    __dotnetenv_pick_java_home "17" || return 1
    __dotnetenv_pick_xcode_dir "${DOTNET9_XCODE_APP:-/Applications/Xcode_16.4.app}" || return 1
  else
    __dotnetenv_pick_java_home "21" || return 1
    __dotnetenv_pick_xcode_dir "${DOTNET10_XCODE_APP:-/Applications/Xcode_26.1.app}" || return 1
  fi

  __dotnetenv_maybe_xcode_select "$select_xcode" || return 1
  __dotnetenv_print_status
}
