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
  use-dotnet9 [--no-select-xcode] [--no-dotnet-move] [--no-cleanup] [--no-workload-restore] [--no-restore]
  use-dotnet10 [--no-select-xcode] [--no-dotnet-move] [--no-cleanup] [--no-workload-restore] [--no-restore]

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
  export DOTNETENV_DOTNET_ROOT="/usr/local/share/dotnet"       # dotnet install root
  export DOTNETENV_DISABLED_DIR="/usr/local/share/dotnet/.env-switcher-disabled"  # storage for moved folders

Notes:
  - If you run the script as an executable (not sourced), exports will NOT persist.
  - VS Code's ".NET MAUI" launcher usually does NOT inherit your terminal's DEVELOPER_DIR.
  - Default behavior switches Xcode system-wide (recommended for VS Code).
      - Or start VS Code from that same terminal after running use-dotnet9/use-dotnet10.
EOF
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
