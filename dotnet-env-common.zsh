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
  use-dotnet9 [--set-xcode [<major.minor>]] [--derive-xcode] [--clear-xcode] [--no-select-xcode] [--no-dotnet-move] [--no-cleanup] [--no-workload-restore] [--no-restore]
  use-dotnet10 [--set-xcode [<major.minor>]] [--derive-xcode] [--clear-xcode] [--no-select-xcode] [--no-dotnet-move] [--no-cleanup] [--no-workload-restore] [--no-restore]

  (If you don't have those functions yet, define them in ~/.zshrc or ~/.zprofile.)

  Example:
    export DOTNET_ENV_SWITCHER_DIR="/path/to/dotnet-env-switcher"
    use-dotnet9()  { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet9.zsh"  "$@"; }
    use-dotnet10() { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet10.zsh" "$@"; }

What it does:
  - Sets JAVA_HOME to JDK 17 (dotnet9) or JDK 21 (dotnet10) via /usr/libexec/java_home
  - Prepends $JAVA_HOME/bin to PATH
  - Sets DEVELOPER_DIR for the matching Xcode.app
  - When switching to dotnet9, disables .NET 10 SDK discovery by moving '10.*' folders out of:
      - /usr/local/share/dotnet/sdk
      - /usr/local/share/dotnet/sdk-manifests
    When switching to dotnet10, re-enables them by moving those folders back.
  - Runs: sudo xcode-select -s "$DEVELOPER_DIR"  (system-wide) by default
    - Use --no-select-xcode to skip the system-wide change
  - By default performs a repo cleanup in the current directory:
      - Deletes all '*.csproj.user' files
      - Runs 'dotnet clean' on a preferred '*.sln' in the current directory (if any)
        - If multiple exist, prefers one that does NOT end with '-all.sln' or '-dev.sln'
      - Runs 'dotnet workload restore' on a preferred '*.sln' in the current directory (if any)
        - If multiple exist, prefers one that does NOT end with '-all.sln' or '-dev.sln'
        - If workloads are installed system-wide and permissions are inadequate, it will retry using sudo.
      - Deletes all 'bin' and 'obj' folders recursively (skipping .git/.vs/node_modules)
      - Runs 'dotnet restore' on a preferred '*.sln' in the current directory (if any)
        - If multiple exist, prefers one that does NOT end with '-all.sln' or '-dev.sln'

  Restore notes:
    - Use --no-restore to skip 'dotnet restore'.

Configuration (optional):
  export DOTNET9_XCODE_APP="/Applications/Xcode_16.4.app"
  export DOTNET10_XCODE_APP="/Applications/Xcode_26.1.app"   # or your actual path
  export DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET9="16.4"      # optional override for auto-selection
  export DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET10="26.2"     # optional override for auto-selection
  export DOTNETENV_DOTNET_ROOT="/usr/local/share/dotnet"       # dotnet install root
  export DOTNETENV_DISABLED_DIR="/usr/local/share/dotnet/.env-switcher-disabled"  # storage for moved folders

Notes:
  - If you run the script as an executable (not sourced), exports will NOT persist.
  - VS Code's ".NET MAUI" launcher usually does NOT inherit your terminal's DEVELOPER_DIR.
  - Default behavior switches Xcode system-wide (recommended for VS Code).
      - Or start VS Code from that same terminal after running use-dotnet9/use-dotnet10.
EOF
}

__dotnetenv_required_xcode_override_version() {
  emulate -L zsh
  local mode="$1"

  # Priority: per-mode override, then global.
  local v=""
  if [[ "$mode" == "dotnet9" && -n "${DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET9:-}" ]]; then
    v="$DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET9"
  elif [[ "$mode" == "dotnet10" && -n "${DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET10:-}" ]]; then
    v="$DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET10"
  elif [[ -n "${DOTNETENV_REQUIRED_XCODE_VERSION:-}" ]]; then
    v="$DOTNETENV_REQUIRED_XCODE_VERSION"
  fi

  [[ -n "${v:-}" ]] || return 1

  local parsed
  parsed="$(__dotnetenv__parse_major_minor "$v" 2>/dev/null)" || return 1
  local major="${parsed%% *}"
  local minor="${parsed#* }"
  print -r -- "$major.$minor"
}

__dotnetenv_pick_sln_in_dir() {
  emulate -L zsh
  setopt null_glob

  local root_dir="$1"
  if [[ -z "${root_dir:-}" ]]; then
    __dotnetenv_die "pick-sln: root directory is empty"
    return 1
  fi

  if [[ ! -d "$root_dir" ]]; then
    __dotnetenv_die "pick-sln: not a directory: $root_dir"
    return 1
  fi

  local -a slns preferred
  slns=("$root_dir"/*.sln(N))

  if (( ${#slns} == 0 )); then
    return 0
  fi

  slns=("${(on)slns[@]}")

  local sln base
  for sln in "${slns[@]}"; do
    base="${sln:t}"
    if [[ "$base" == *-all.sln || "$base" == *-dev.sln ]]; then
      continue
    fi
    preferred+=("$sln")
  done

  if (( ${#preferred} > 0 )); then
    preferred=("${(on)preferred[@]}")
    print -r -- "${preferred[1]}"
    return 0
  fi

  print -r -- "${slns[1]}"
}

__dotnetenv_sanitize_project_path_arg() {
  emulate -L zsh
  setopt extended_glob

  local p="$1"
  p="${p%$'\r'}"
  p="${p##[[:space:]]#}"
  p="${p%%[[:space:]]#}"

  # Strip a leading key=value prefix (e.g. abs=/path/to.csproj).
  if [[ "$p" == [A-Za-z_][A-Za-z0-9_]#=* ]]; then
    p="${p#*=}"
  fi

  # Normalize Windows-style paths.
  p="${p//\\//}"

  print -r -- "$p"
}

__dotnetenv_is_unittests_project_path() {
  emulate -L zsh

  local p="$1"
  p="$(__dotnetenv_sanitize_project_path_arg "$p")"

  local pl="${p:l}"
  local base="${p:t:l}"

  # Folder-based convention.
  if [[ "$pl" == */unittests/* ]]; then
    return 0
  fi

  # Name-based convention (e.g. Esri.AppModule.Survey123.UnitTests.csproj)
  if [[ "$base" == *.csproj && "$base" == *unittests* ]]; then
    return 0
  fi

  return 1
}

__dotnetenv_solution_has_unittests_projects() {
  emulate -L zsh
  local sln="$1"

  if [[ -z "${sln:-}" || ! -f "$sln" ]]; then
    return 1
  fi

  # Best-effort detection: does the solution reference any csproj under a UnitTests folder?
  if command -v grep >/dev/null 2>&1; then
    if grep -qiE 'unittests.*\.csproj|\.csproj.*unittests' "$sln"; then
      return 0
    fi
  fi

  return 1
}

__dotnetenv_list_solution_projects_excluding_unittests() {
  emulate -L zsh
  setopt null_glob
  setopt extended_glob

  local sln="$1"
  if [[ -z "${sln:-}" ]]; then
    __dotnetenv_die "list-sln-projects: sln path is empty"
    return 1
  fi

  if [[ ! -f "$sln" ]]; then
    __dotnetenv_die "list-sln-projects: sln not found: $sln"
    return 1
  fi

  local sln_dir="${sln:h}"
  local -a included

  # Prefer asking dotnet to enumerate the solution projects.
  # This is more robust than parsing the .sln format ourselves.
  if command -v dotnet >/dev/null 2>&1; then
    local output
    output="$(dotnet sln "$sln" list 2>/dev/null)"
    if [[ -n "${output:-}" ]]; then
      local line
      while IFS= read -r line; do
        line="$(__dotnetenv_sanitize_project_path_arg "$line")"

        [[ -n "${line:-}" ]] || continue
        [[ "${line:l}" == *.csproj ]] || continue

        if __dotnetenv_is_unittests_project_path "$line"; then
          continue
        fi

        local abs
        if [[ "$line" == /* ]]; then
          abs="$line"
        else
          abs="$sln_dir/$line"
        fi

        [[ -f "$abs" ]] || continue
        included+=("$abs")
      done <<< "$output"

      local p
      for p in "${included[@]}"; do
        [[ -n "${p:-}" ]] || continue
        print -r -- "$p"
      done

      return 0
    fi
  fi

  local line
  while IFS= read -r line; do
    line="$(__dotnetenv_sanitize_project_path_arg "$line")"

    # Typical line:
    #   Project("{GUID}") = "Name", "relative\\path\\proj.csproj", "{GUID}"
    [[ "$line" == Project\(* ]] || continue

    local -a parts
    parts=("${(@s/\"/)line}")
    (( ${#parts} >= 6 )) || continue

    local rel
    rel="$(__dotnetenv_sanitize_project_path_arg "${parts[6]}")"
    [[ "$rel" == *.csproj ]] || continue

    if __dotnetenv_is_unittests_project_path "$rel"; then
      continue
    fi

    local abs="$sln_dir/$rel"
    if [[ "$rel" == /* ]]; then
      abs="$rel"
    fi
    [[ -f "$abs" ]] || continue

    included+=("$abs")
  done < "$sln"

  local p
  for p in "${included[@]}"; do
    [[ -n "${p:-}" ]] || continue
    print -r -- "$p"
  done
}

__dotnetenv_dotnet_root() {
  local root="${DOTNETENV_DOTNET_ROOT:-}"
  if [[ -n "${root:-}" ]]; then
    print -r -- "$root"
    return 0
  fi

  # Prefer resolving the dotnet binary location, since Homebrew and the official
  # installer can install into different prefixes (/usr/local vs /opt/homebrew).
  if command -v dotnet >/dev/null 2>&1; then
    local dotnet_bin resolved
    dotnet_bin="$(command -v dotnet)"
    # :A resolves to an absolute path and resolves symlinks in zsh.
    resolved="${dotnet_bin:A}"
    root="$(dirname -- "$resolved")"
    print -r -- "$root"
    return 0
  fi

  # Fallback (most common on Intel Macs).
  print -r -- "/usr/local/share/dotnet"
}

__dotnetenv_disabled_root() {
  local root
  root="$(__dotnetenv_dotnet_root)"
  print -r -- "${DOTNETENV_DISABLED_DIR:-$root/.env-switcher-disabled}"
}

__dotnetenv_mkdir_p() {
  local dir="$1"
  if [[ -z "${dir:-}" ]]; then
    __dotnetenv_die "mkdir: directory is empty"
    return 1
  fi

  if [[ -d "$dir" ]]; then
    return 0
  fi

  local parent
  parent="$(dirname -- "$dir")"
  if [[ -w "$parent" ]]; then
    mkdir -p -- "$dir"
  else
    sudo mkdir -p -- "$dir"
  fi
}

__dotnetenv_move_matching_dirs() {
  emulate -L zsh
  setopt extended_glob
  setopt null_glob
  unsetopt nomatch

  local src_base="$1"
  local dst_base="$2"
  local pattern="$3"
  local label="$4"

  if [[ -z "${src_base:-}" || -z "${dst_base:-}" || -z "${pattern:-}" ]]; then
    __dotnetenv_die "move-dirs: missing arguments"
    return 1
  fi

  if [[ ! -d "$src_base" ]]; then
    # If the dotnet install isn't in this location, don't hard-fail.
    __dotnetenv_warn "$label: not found: $src_base (skipping)"
    return 0
  fi

  local -a matches
  # Use ${~pattern} so the pattern string is treated as a glob pattern.
  # (Without this, a pattern coming from a variable may not behave as expected
  # under certain option sets.)
  matches=("$src_base"/${~pattern}(N/))
  if (( ${#matches} == 0 )); then
    print -r -- "$label: no matching folders found in '$src_base' (pattern: ${pattern})."
    return 0
  fi

  __dotnetenv_mkdir_p "$dst_base" || return 1

  local moved=0
  local src
  for src in "${matches[@]}"; do
    local name dst
    name="${src:t}"
    dst="$dst_base/$name"

    if [[ -e "$dst" ]]; then
      __dotnetenv_warn "$label: destination already exists (skipping): $dst"
      continue
    fi

    if [[ -w "$src_base" && -w "$dst_base" ]]; then
      mv -- "$src" "$dst"
    else
      sudo mv -- "$src" "$dst"
    fi
    (( moved++ ))
  done

  if (( moved > 0 )); then
    print -r -- "$label: moved $moved folder(s)."
  fi
}

__dotnetenv_disable_dotnet10() {
  local dotnet_root disabled_root
  dotnet_root="$(__dotnetenv_dotnet_root)"
  disabled_root="$(__dotnetenv_disabled_root)"

  print -r -- ""
  print -r -- "Disabling .NET 10 SDK folders (moving '10.*' out of dotnet root): $dotnet_root"

  __dotnetenv_move_matching_dirs \
    "$dotnet_root/sdk" \
    "$disabled_root/sdk" \
    '10.*' \
    '.NET SDK (10.*)' || return 1

  __dotnetenv_move_matching_dirs \
    "$dotnet_root/sdk-manifests" \
    "$disabled_root/sdk-manifests" \
    '10.*' \
    'SDK manifests (10.*)' || return 1
}

__dotnetenv_enable_dotnet10() {
  local dotnet_root disabled_root
  dotnet_root="$(__dotnetenv_dotnet_root)"
  disabled_root="$(__dotnetenv_disabled_root)"

  print -r -- ""
  print -r -- "Enabling .NET 10 SDK folders (moving '10.*' back into dotnet root): $dotnet_root"

  __dotnetenv_move_matching_dirs \
    "$disabled_root/sdk" \
    "$dotnet_root/sdk" \
    '10.*' \
    '.NET SDK (10.*)' || return 1

  __dotnetenv_move_matching_dirs \
    "$disabled_root/sdk-manifests" \
    "$dotnet_root/sdk-manifests" \
    '10.*' \
    'SDK manifests (10.*)' || return 1
}

__dotnetenv_dotnet_workload_restore_sln() {
  local root_dir="$1"
  local sln

  if [[ ! -d "$root_dir" ]]; then
    __dotnetenv_die "dotnet-workload-restore: not a directory: $root_dir"
    return 1
  fi

  # Only look in the current directory (not recursive) to match the common "repo root" workflow.
  sln="$(__dotnetenv_pick_sln_in_dir "$root_dir")" || return 1
  if [[ -z "${sln:-}" ]]; then
    __dotnetenv_warn "No .sln found in '$root_dir' (skipping dotnet workload restore)."
    return 0
  fi

  print -r -- ""
  local -a targets
  targets=("${(@f)$(__dotnetenv_list_solution_projects_excluding_unittests "$sln")}") || return 1

  local -a filtered
  local t
  for t in "${targets[@]}"; do
    t="$(__dotnetenv_sanitize_project_path_arg "$t")"
    [[ -n "${t:-}" ]] || continue
    [[ -f "$t" ]] || continue
    filtered+=("$t")
  done
  targets=("${filtered[@]}")

  if (( ${#targets} == 0 )); then
    if __dotnetenv_solution_has_unittests_projects "$sln"; then
      __dotnetenv_warn "No non-UnitTests projects found in $(basename -- "$sln"); skipping dotnet workload restore."
      return 0
    fi

    targets=("$sln")
  fi

  if (( ${#targets} == 1 )) && [[ "${targets[1]}" == "$sln" ]]; then
    print -r -- "Running: dotnet workload restore $(basename -- "$sln")"
  else
    print -r -- "Running: dotnet workload restore (excluding UnitTests projects)"
  fi

  local is_json_failure
  is_json_failure() {
    # Common symptom when workload manifest/update JSON is corrupted or replaced by a proxy/HTML.
    # Keep this deliberately broad but specific to JSON parsing failures.
    grep -qiE 'Workload update failed|Expected end of data|invalid after a single JSON value|invalid.*JSON'
  }

  local target
  for target in "${targets[@]}"; do
    target="$(__dotnetenv_sanitize_project_path_arg "$target")"
    [[ -n "${target:-}" ]] || continue

    # Try without sudo first (works for user-local workload installs).
    # If we hit a manifest-update JSON parsing failure, retry with --skip-manifest-update.
    local output rc
    output="$(dotnet workload restore "$target" 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      print -r -- "$output" >&2

      # If workloads are installed system-wide, dotnet may require elevated privileges.
      if print -r -- "$output" | grep -qiE 'Inadequate permissions|elevated privileges'; then
        __dotnetenv_warn "dotnet workload restore needs elevated privileges; retrying with sudo"
        output="$(sudo dotnet workload restore "$target" 2>&1)"
        rc=$?
        if (( rc == 0 )); then
          print -r -- "$output"
          continue
        fi

        print -r -- "$output" >&2

        if print -r -- "$output" | is_json_failure; then
          __dotnetenv_warn "workload restore failed during manifest update; retrying with --skip-manifest-update"
          output="$(sudo dotnet workload restore "$target" --skip-manifest-update 2>&1)"
          rc=$?
          if (( rc == 0 )); then
            print -r -- "$output"
            continue
          fi

          print -r -- "$output" >&2
          if print -r -- "$output" | is_json_failure; then
            __dotnetenv_warn "workload restore still failing due to JSON parse errors; skipping workload restore for this run."
            __dotnetenv_warn "Workaround: run 'sudo dotnet workload restore --skip-manifest-update' later when your network/proxy is stable."
            return 0
          fi

          return $rc
        fi

        return $rc
      fi

      if print -r -- "$output" | is_json_failure; then
        __dotnetenv_warn "workload restore failed during manifest update; retrying with --skip-manifest-update"
        output="$(dotnet workload restore "$target" --skip-manifest-update 2>&1)"
        rc=$?
        if (( rc == 0 )); then
          print -r -- "$output"
          continue
        fi

        print -r -- "$output" >&2
        if print -r -- "$output" | is_json_failure; then
          __dotnetenv_warn "workload restore still failing due to JSON parse errors; skipping workload restore for this run."
          __dotnetenv_warn "Workaround: run 'dotnet workload restore --skip-manifest-update' later when your network/proxy is stable."
          return 0
        fi

        return $rc
      fi

      return $rc
    fi

    print -r -- "$output"
  done
}

__dotnetenv_dotnet_restore_sln() {
  local root_dir="$1"
  local sln

  if [[ ! -d "$root_dir" ]]; then
    __dotnetenv_die "dotnet-restore: not a directory: $root_dir"
    return 1
  fi

  # Only look in the current directory (not recursive) to match the common "repo root" workflow.
  sln="$(__dotnetenv_pick_sln_in_dir "$root_dir")" || return 1
  if [[ -z "${sln:-}" ]]; then
    __dotnetenv_warn "No .sln found in '$root_dir' (skipping dotnet restore)."
    return 0
  fi

  local -a targets
  targets=("${(@f)$(__dotnetenv_list_solution_projects_excluding_unittests "$sln")}") || return 1

  local -a filtered
  local t
  for t in "${targets[@]}"; do
    t="$(__dotnetenv_sanitize_project_path_arg "$t")"
    [[ -n "${t:-}" ]] || continue
    [[ -f "$t" ]] || continue
    filtered+=("$t")
  done
  targets=("${filtered[@]}")

  if (( ${#targets} == 0 )); then
    if __dotnetenv_solution_has_unittests_projects "$sln"; then
      __dotnetenv_warn "No non-UnitTests projects found in $(basename -- "$sln"); skipping dotnet restore."
      return 0
    fi

    targets=("$sln")
  fi

  local target
  for target in "${targets[@]}"; do
    target="$(__dotnetenv_sanitize_project_path_arg "$target")"
    [[ -n "${target:-}" ]] || continue

    print -r -- ""
    print -r -- "Running: dotnet restore $(basename -- "$target")"

    local output rc
    output="$(dotnet restore "$target" 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      print -r -- "$output" >&2
      return $rc
    fi

    print -r -- "$output"
  done
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
  sln="$(__dotnetenv_pick_sln_in_dir "$root_dir")" || return 1
  if [[ -z "${sln:-}" ]]; then
    __dotnetenv_warn "No .sln found in '$root_dir' (skipping dotnet clean)."
    return 0
  fi

  local -a targets
  targets=("${(@f)$(__dotnetenv_list_solution_projects_excluding_unittests "$sln")}") || return 1

  local -a filtered
  local t
  for t in "${targets[@]}"; do
    t="$(__dotnetenv_sanitize_project_path_arg "$t")"
    [[ -n "${t:-}" ]] || continue
    [[ -f "$t" ]] || continue
    filtered+=("$t")
  done
  targets=("${filtered[@]}")

  if (( ${#targets} == 0 )); then
    if __dotnetenv_solution_has_unittests_projects "$sln"; then
      __dotnetenv_warn "No non-UnitTests projects found in $(basename -- "$sln"); skipping dotnet clean."
      return 0
    fi

    targets=("$sln")
  fi

  local target
  for target in "${targets[@]}"; do
    target="$(__dotnetenv_sanitize_project_path_arg "$target")"
    [[ -n "${target:-}" ]] || continue

    print -r -- ""
    print -r -- "Running: dotnet clean $(basename -- "$target")"

    # dotnet clean can fail if a previous restore generated a project.assets.json that
    # doesn't include the current TFM/RID (common when switching branches/toolchains).
    # Treat selected NETSDK10xx errors as non-fatal cleanup issues so environment switching can continue.
    local output rc
    output="$(dotnet clean "$target" -v minimal 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      if print -r -- "$output" | grep -qE 'NETSDK1047|NETSDK1004|NETSDK1013'; then
        if print -r -- "$output" | grep -qE 'NETSDK1013'; then
          __dotnetenv_warn "dotnet clean failed due to an invalid/empty TargetFramework (NETSDK1013)."
          __dotnetenv_warn "Suggestion: fix the project's TargetFramework/TargetFrameworks (it evaluated to empty), then rerun restore/build."
        else
          __dotnetenv_warn "dotnet clean failed due to missing/mismatched restore assets (NETSDK10xx)."
          __dotnetenv_warn "Suggestion: run 'dotnet restore' for the solution (for MacCatalyst often: -r maccatalyst-arm64)."
        fi
        __dotnetenv_warn "Continuing."
        continue
      fi

      print -r -- "$output" >&2
      return $rc
    fi

    print -r -- "$output"
  done
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
  local do_workload_restore="${2:-1}"
  local do_restore="${3:-1}"

  __dotnetenv_purge_user_files "$root_dir" || return 1
  __dotnetenv_dotnet_clean_sln "$root_dir" || return 1
  __dotnetenv_delete_bin_obj "$root_dir" || return 1

  if [[ "$do_workload_restore" == "1" ]]; then
    __dotnetenv_dotnet_workload_restore_sln "$root_dir" || return 1
  fi

  if [[ "$do_restore" == "1" ]]; then
    __dotnetenv_dotnet_restore_sln "$root_dir" || return 1
  fi
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

__dotnetenv__parse_first_int() {
  emulate -L zsh
  local s="$1"
  local n
  if [[ "$s" =~ '([0-9]+)' ]]; then
    n="${match[1]}"
    print -r -- "$n"
    return 0
  fi
  return 1
}

__dotnetenv__parse_major_minor() {
  emulate -L zsh
  local s="$1"
  local major minor

  if [[ "$s" =~ '([0-9]+)\.([0-9]+)' ]]; then
    major="${match[1]}"
    minor="${match[2]}"
    print -r -- "$major $minor"
    return 0
  fi

  if [[ "$s" =~ '([0-9]+)' ]]; then
    major="${match[1]}"
    print -r -- "$major 0"
    return 0
  fi

  return 1
}

__dotnetenv_xcode_version_for_app() {
  emulate -L zsh
  local app="$1"
  local plist="$app/Contents/Info.plist"
  if [[ -z "${app:-}" || ! -d "$app" || ! -f "$plist" ]]; then
    return 1
  fi

  local ver
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
  fi

  if [[ -z "${ver:-}" ]]; then
    # Fallback: derive from common bundle naming conventions.
    # Examples:
    #   Xcode_16.4.app  -> 16.4
    #   Xcode_26.1.app  -> 26.1
    #   Xcode_26.app    -> 26.0
    local name="${app:t}"
    if [[ "$name" =~ '^Xcode[_-]([0-9]+)\.([0-9]+)\.app$' ]]; then
      print -r -- "${match[1]}.${match[2]}"
      return 0
    fi
    if [[ "$name" =~ '^Xcode[_-]([0-9]+)\.app$' ]]; then
      print -r -- "${match[1]}.0"
      return 0
    fi

    return 1
  fi

  # Normalize to major.minor (minor optional).
  if [[ "$ver" =~ '^([0-9]+)\.([0-9]+)' ]]; then
    print -r -- "${match[1]}.${match[2]}"
    return 0
  fi
  if [[ "$ver" =~ '^([0-9]+)$' ]]; then
    print -r -- "${match[1]}.0"
    return 0
  fi

  return 1
}

__dotnetenv_list_xcode_apps() {
  emulate -L zsh
  setopt null_glob

  local -a apps
  apps=(/Applications/Xcode*.app(N) ~/Applications/Xcode*.app(N))
  apps=("${(on)apps[@]}")

  local a
  for a in "${apps[@]}"; do
    [[ -d "$a/Contents/Developer" ]] || continue
    print -r -- "$a"
  done
}

__dotnetenv_guess_apple_platform_major_from_repo() {
  emulate -L zsh

  local root_dir="$1"
  if [[ -z "${root_dir:-}" || ! -d "$root_dir" ]]; then
    return 1
  fi

  local sln
  sln="$(__dotnetenv_pick_sln_in_dir "$root_dir")" || return 1
  if [[ -z "${sln:-}" || ! -f "$sln" ]]; then
    return 1
  fi

  local -a projects
  projects=("${(@f)$(__dotnetenv_list_solution_projects_excluding_unittests "$sln")}") || return 1
  if (( ${#projects} == 0 )); then
    return 1
  fi

  local max_major=0
  local p content
  for p in "${projects[@]}"; do
    [[ -f "$p" ]] || continue
    content="$(tr -d '\n\r\t ' < "$p" 2>/dev/null)"
    [[ -n "${content:-}" ]] || continue

    # Look for TFMs like: net9.0-ios18.0, net8.0-maccatalyst17.4, etc.
    local rest="$content"
    while [[ "$rest" =~ 'net[0-9]+\.[0-9]+-(ios|maccatalyst|tvos|macos)([0-9]+)(\.[0-9]+)?' ]]; do
      local major="${match[2]}"
      if [[ -n "${major:-}" ]] && (( major > max_major )); then
        max_major=$major
      fi
      rest="${rest#*${match[0]}}"
    done
  done

  if (( max_major > 0 )); then
    print -r -- "$max_major"
    return 0
  fi

  return 1
}

__dotnetenv_guess_apple_platform_major_from_installed_packs() {
  emulate -L zsh
  setopt null_glob

  local -a roots
  roots=("$(__dotnetenv_dotnet_root 2>/dev/null)" "$HOME/.dotnet" "/usr/local/share/dotnet")

  local -a candidates
  local r
  for r in "${roots[@]}"; do
    [[ -n "${r:-}" && -d "$r" ]] || continue
    candidates+=(
      "$r/packs/Microsoft.iOS.Sdk"(N)
      "$r/packs/Microsoft.MacCatalyst.Sdk"(N)
    )
  done

  local max_major=0
  local pack_root
  for pack_root in "${candidates[@]}"; do
    [[ -d "$pack_root" ]] || continue
    local -a vers
    vers=("$pack_root"/*(N/))
    if (( ${#vers} == 0 )); then
      continue
    fi

    local v base major
    for v in "${vers[@]}"; do
      base="${v:t}"
      major="$(__dotnetenv__parse_first_int "$base")" || continue
      if (( major > max_major )); then
        max_major=$major
      fi
    done
  done

  if (( max_major > 0 )); then
    print -r -- "$max_major"
    return 0
  fi

  return 1
}

__dotnetenv_guess_required_xcode_version_from_installed_packs() {
  emulate -L zsh
  setopt null_glob
  local XTRACEFD=2
  set +x

  # mode: dotnet9 -> net9.0, dotnet10 -> net10.0
  local mode="$1"
  local tfm=""
  if [[ "$mode" == "dotnet9" ]]; then
    tfm="net9.0"
  elif [[ "$mode" == "dotnet10" ]]; then
    tfm="net10.0"
  else
    return 1
  fi

  local -a roots
  roots=("$(__dotnetenv_dotnet_root 2>/dev/null)" "$HOME/.dotnet" "/usr/local/share/dotnet")

  # Collect candidate xcode versions inferred from pack folder names and version folders.
  local best_major=-1
  local best_minor=-1

  local root pack_dir base parsed major minor
  for root in "${roots[@]}"; do
    [[ -n "${root:-}" && -d "$root" ]] || continue

    # Pack folder name conventions seen in the wild:
    #   packs/Microsoft.iOS.Sdk.net10.0_26.1/
    #   packs/Microsoft.MacCatalyst.Sdk.net10.0_26.1/
    for pack_dir in "$root/packs/Microsoft.iOS.Sdk.${tfm}_"*(N/) "$root/packs/Microsoft.MacCatalyst.Sdk.${tfm}_"*(N/); do
      [[ -d "$pack_dir" ]] || continue
      base="${pack_dir:t}"

      # Extract suffix after "${tfm}_".
      local suffix="${base#*${tfm}_}"
      parsed="$(__dotnetenv__parse_major_minor "$suffix" 2>/dev/null)" || parsed=""
      if [[ -n "${parsed:-}" ]]; then
        major="${parsed%% *}"
        minor="${parsed#* }"
        if (( major > best_major )) || { (( major == best_major )) && (( minor > best_minor )); }; then
          best_major=$major
          best_minor=$minor
        fi
      fi

      # Also consider the installed version folders: e.g. 26.1.10502
      local vdir vname
      for vdir in "$pack_dir"/*(N/); do
        vname="${vdir:t}"
        parsed="$(__dotnetenv__parse_major_minor "$vname" 2>/dev/null)" || parsed=""
        [[ -n "${parsed:-}" ]] || continue
        major="${parsed%% *}"
        minor="${parsed#* }"
        if (( major > best_major )) || { (( major == best_major )) && (( minor > best_minor )); }; then
          best_major=$major
          best_minor=$minor
        fi
      done
    done
  done

  if (( best_major > 0 )); then
    REPLY="$best_major.$best_minor"
    return 0
  fi

  return 1
}

__dotnetenv_guess_required_xcode_version() {
  emulate -L zsh
  local XTRACEFD=2
  set +x
  local root_dir="$1"
  local mode="$2"

  # Explicit override (most deterministic).
  local override
  override="$(__dotnetenv_required_xcode_override_version "$mode" 2>/dev/null)" || override=""
  if [[ -n "${override:-}" ]]; then
    DOTNETENV_LAST_XCODE_REQUIRED_SOURCE="override"
    REPLY="$override"
    return 0
  fi

  # Primary (most accurate): infer required Xcode major.minor from installed Apple packs.
  local required
  if __dotnetenv_guess_required_xcode_version_from_installed_packs "$mode" 2>/dev/null; then
    required="$REPLY"
  else
    required=""
  fi
  if [[ -n "${required:-}" ]]; then
    DOTNETENV_LAST_XCODE_REQUIRED_SOURCE="packs"
    REPLY="$required"
    return 0
  fi

  # Fallback: infer Apple platform major from TFMs/installed packs, then apply heuristic.
  local apple_major
  apple_major="$(__dotnetenv_guess_apple_platform_major_from_repo "$root_dir" 2>/dev/null)" || true
  if [[ -z "${apple_major:-}" ]]; then
    apple_major="$(__dotnetenv_guess_apple_platform_major_from_installed_packs 2>/dev/null)" || true
  fi

  if [[ -z "${apple_major:-}" ]]; then
    return 1
  fi

  # Heuristic: iOS/macOS platform major N typically ships with Xcode (N-2).
  local xcode_major=$(( apple_major - 2 ))
  if (( xcode_major <= 0 )); then
    return 1
  fi

  DOTNETENV_LAST_XCODE_REQUIRED_SOURCE="heuristic"

  REPLY="$xcode_major.0"
  return 0
}

__dotnetenv_pick_xcode_app_auto() {
  emulate -L zsh
  local XTRACEFD=2
  set +x

  local root_dir="$1"
  local mode="$2"
  local required_version
  if __dotnetenv_guess_required_xcode_version "$root_dir" "$mode" 2>/dev/null; then
    required_version="$REPLY"
  else
    required_version=""
  fi
  DOTNETENV_LAST_XCODE_REQUIRED_VERSION="$required_version"
  local required_major="" required_minor=""
  if [[ -n "${required_version:-}" ]]; then
    local parsed
    parsed="$(__dotnetenv__parse_major_minor "$required_version" 2>/dev/null)" || parsed=""
    if [[ -n "${parsed:-}" ]]; then
      required_major="${parsed%% *}"
      required_minor="${parsed#* }"
    fi
  fi

  local -a apps
  apps=("${(@f)$(__dotnetenv_list_xcode_apps)}")
  if (( ${#apps} == 0 )); then
    __dotnetenv_die "No Xcode*.app found under /Applications or ~/Applications"
    return 1
  fi

  # Build a list of "major minor app" rows so we can sort easily.
  local -a rows
  local app ver major minor
  for app in "${apps[@]}"; do
    ver="$(__dotnetenv_xcode_version_for_app "$app" 2>/dev/null)" || continue
    major="$(__dotnetenv__parse_first_int "${ver%%.*}")" || continue
    minor="$(__dotnetenv__parse_first_int "${ver#*.}")" || minor=0
    rows+=("$major $minor $app")
  done

  if (( ${#rows} == 0 )); then
    __dotnetenv_die "Unable to read Xcode version from installed apps"
    return 1
  fi

  local best_app=""
  if [[ -n "${required_major:-}" ]]; then
    # Prefer the smallest minor that satisfies the requirement (>=), to avoid surprising jumps.
    local best_minor=999999
    local row
    for row in "${rows[@]}"; do
      major="${row%% *}"
      minor="${row#* }"; minor="${minor%% *}"
      app="${row#* * }"

      if (( major == required_major )) && (( minor >= required_minor )) && (( minor < best_minor )); then
        best_minor=$minor
        best_app="$app"
      fi
    done

    if [[ -n "${best_app:-}" ]]; then
      print -r -- "$best_app"
      return 0
    fi

    # If the user explicitly overrode the required version, be strict.
    if [[ "${DOTNETENV_LAST_XCODE_REQUIRED_SOURCE:-}" == "override" ]]; then
      __dotnetenv_die "Required Xcode ${required_major}.${required_minor} not found under /Applications or ~/Applications"
      return 1
    fi

    __dotnetenv_warn "Could not find an installed Xcode ${required_major}.${required_minor}; falling back to newest installed Xcode"
  fi

  # Fallback: pick newest by major/minor.
  local best_major=-1 best_minor=-1
  local row
  for row in "${rows[@]}"; do
    major="${row%% *}"
    minor="${row#* }"; minor="${minor%% *}"
    app="${row#* * }"

    if (( major > best_major )) || { (( major == best_major )) && (( minor > best_minor )); }; then
      best_major=$major
      best_minor=$minor
      best_app="$app"
    fi
  done

  if [[ -z "${best_app:-}" ]]; then
    __dotnetenv_die "Could not determine a usable Xcode.app"
    return 1
  fi

  print -r -- "$best_app"
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

  local before after
  before="$(xcode-select -p 2>/dev/null)"

  print -r -- ""
  print -r -- "xcode-select (global) before: ${before:-<unknown>}"
  __dotnetenv_warn "Running: sudo xcode-select -s '$DEVELOPER_DIR'"
  sudo xcode-select -s "$DEVELOPER_DIR" || return $?

  after="$(xcode-select -p 2>/dev/null)"
  print -r -- "xcode-select (global) after:  ${after:-<unknown>}"

  if [[ -n "${after:-}" && "$after" != "$DEVELOPER_DIR" ]]; then
    __dotnetenv_warn "Global xcode-select path does not match DEVELOPER_DIR. Some tools may still resolve Xcode differently."
  fi
}

__dotnetenv_print_status() {
  print -r -- ""
  print -r -- "Toolchain status:"
  print -r -- "  JAVA_HOME     = ${JAVA_HOME:-<unset>}"
  print -r -- "  DEVELOPER_DIR = ${DEVELOPER_DIR:-<unset>}"

  if command -v xcode-select >/dev/null 2>&1; then
    local xcode_global
    xcode_global="$(xcode-select -p 2>/dev/null)"
    print -r -- "  xcode-select -p (global) = ${xcode_global:-<unknown>}"
  fi

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

__dotnetenv_java_version_line() {
  if command -v java >/dev/null 2>&1; then
    java -version 2>&1 | sed -n '1p'
  else
    print -r -- "<not found>"
  fi
}

__dotnetenv_xcodebuild_version_line() {
  if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -version 2>/dev/null | sed -n '1p'
  else
    print -r -- "<not found>"
  fi
}

__dotnetenv_dotnet_version_line() {
  if command -v dotnet >/dev/null 2>&1; then
    dotnet --version 2>/dev/null | sed -n '1p'
  else
    print -r -- "<not found>"
  fi
}

__dotnetenv_xcode_select_path() {
  if command -v xcode-select >/dev/null 2>&1; then
    xcode-select -p 2>/dev/null | sed -n '1p'
  else
    print -r -- "<not found>"
  fi
}

__dotnetenv_format_change() {
  emulate -L zsh
  local before="$1"
  local after="$2"
  before="${before:-<unset>}"
  after="${after:-<unset>}"
  if [[ "$before" == "$after" ]]; then
    print -r -- "$after (unchanged)"
  else
    print -r -- "$before -> $after"
  fi
}

__dotnetenv_print_run_summary() {
  local mode="$1"
  local select_xcode="$2"
  local did_dotnet_move="$3"
  local did_cleanup="$4"
  local did_workload_restore="$5"
  local did_restore="$6"

  local before_java_home="$7"
  local before_java_ver="$8"
  local before_developer_dir="$9"
  shift 9
  local before_xcode_select="$1"
  local before_xcodebuild="$2"
  local before_dotnet="$3"

  local after_java_home="${JAVA_HOME:-}"
  local after_java_ver
  after_java_ver="$(__dotnetenv_java_version_line)"

  local after_developer_dir="${DEVELOPER_DIR:-}"
  local after_xcode_select
  after_xcode_select="$(__dotnetenv_xcode_select_path)"

  local after_xcodebuild
  after_xcodebuild="$(__dotnetenv_xcodebuild_version_line)"

  local after_dotnet
  after_dotnet="$(__dotnetenv_dotnet_version_line)"

  print -r -- ""
  print -r -- "Summary:"
  print -r -- "  Mode: $mode"

  if [[ -n "${DOTNETENV_LAST_XCODE_REQUIRED_VERSION:-}" ]]; then
    local src="${DOTNETENV_LAST_XCODE_REQUIRED_SOURCE:-unknown}"
    print -r -- "  Required Xcode: ${DOTNETENV_LAST_XCODE_REQUIRED_VERSION} (${src})"
  fi

  if [[ -n "${DOTNETENV_LAST_XCODE_APP:-}" ]]; then
    print -r -- "  Xcode app: ${DOTNETENV_LAST_XCODE_APP} (${DOTNETENV_LAST_XCODE_SOURCE:-unknown})"
  fi

  print -r -- "  JAVA_HOME: $(__dotnetenv_format_change "$before_java_home" "$after_java_home")"
  print -r -- "  java: $(__dotnetenv_format_change "$before_java_ver" "$after_java_ver")"
  print -r -- "  DEVELOPER_DIR: $(__dotnetenv_format_change "$before_developer_dir" "$after_developer_dir")"
  print -r -- "  xcodebuild: $(__dotnetenv_format_change "$before_xcodebuild" "$after_xcodebuild")"
  print -r -- "  xcode-select -p (global): $(__dotnetenv_format_change "$before_xcode_select" "$after_xcode_select")"
  print -r -- "  dotnet: $(__dotnetenv_format_change "$before_dotnet" "$after_dotnet")"

  print -r -- ""
  print -r -- "Completed steps:"
  if [[ "$did_dotnet_move" == "1" ]]; then
    if [[ "$mode" == "dotnet9" ]]; then
      print -r -- "  - .NET SDK move: disabled 10.* discovery"
    else
      print -r -- "  - .NET SDK move: enabled 10.* discovery"
    fi
  else
    print -r -- "  - .NET SDK move: skipped (--no-dotnet-move)"
  fi

  if [[ "$select_xcode" == "1" ]]; then
    print -r -- "  - xcode-select: updated system-wide"
  else
    print -r -- "  - xcode-select: skipped (--no-select-xcode)"
  fi

  if [[ "$did_cleanup" == "1" ]]; then
    print -r -- "  - Cleanup: ran"
    if [[ "$did_workload_restore" == "1" ]]; then
      print -r -- "    - dotnet workload restore: ran"
    else
      print -r -- "    - dotnet workload restore: skipped (--no-workload-restore)"
    fi
    if [[ "$did_restore" == "1" ]]; then
      print -r -- "    - dotnet restore: ran"
    else
      print -r -- "    - dotnet restore: skipped (--no-restore)"
    fi
    print -r -- "    - dotnet clean / delete bin+obj / delete *.csproj.user: attempted (see logs above)"
  else
    print -r -- "  - Cleanup: skipped (--no-cleanup)"
  fi
}

__dotnetenv_apply() {
  local mode="$1"           # dotnet9 | dotnet10
  local select_xcode="$2"   # 0 | 1
  local root_dir="${3:-$(pwd)}"

  if [[ "$mode" != "dotnet9" && "$mode" != "dotnet10" ]]; then
    __dotnetenv_die "Unknown mode: $mode"
    return 1
  fi

  local xcode_app=""
  local xcode_source=""
  local auto_xcode="${DOTNETENV_XCODE_AUTO:-1}"
  local force_auto="${DOTNETENV_FORCE_XCODE_AUTO:-0}"

  if [[ "$mode" == "dotnet9" ]]; then
    __dotnetenv_pick_java_home "17" || return 1
    if [[ "$force_auto" != "1" && -n "${DOTNET9_XCODE_APP:-}" ]]; then
      xcode_app="${DOTNET9_XCODE_APP}"
      xcode_source="env"
    fi
  else
    __dotnetenv_pick_java_home "21" || return 1
    if [[ "$force_auto" != "1" && -n "${DOTNET10_XCODE_APP:-}" ]]; then
      xcode_app="${DOTNET10_XCODE_APP}"
      xcode_source="env"
    fi
  fi

  if [[ -z "${xcode_app:-}" && ( "$auto_xcode" == "1" || "$force_auto" == "1" ) ]]; then
    xcode_app="$(__dotnetenv_pick_xcode_app_auto "$root_dir" "$mode")" || return 1
    xcode_source="auto"
  fi

  # Back-compat fallback if auto is disabled and no app was provided.
  if [[ -z "${xcode_app:-}" ]]; then
    if [[ "$mode" == "dotnet9" ]]; then
      xcode_app="/Applications/Xcode_16.4.app"
    else
      xcode_app="/Applications/Xcode_26.1.app"
    fi
    xcode_source="default"
  fi

  DOTNETENV_LAST_MODE="$mode"
  DOTNETENV_LAST_XCODE_APP="$xcode_app"
  DOTNETENV_LAST_XCODE_SOURCE="$xcode_source"

  __dotnetenv_pick_xcode_dir "$xcode_app" || return 1

  __dotnetenv_maybe_xcode_select "$select_xcode" || return 1
  __dotnetenv_print_status
}
