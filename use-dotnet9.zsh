#!/usr/bin/env zsh

# Switch shell toolchain to match the repo's .NET 9 workflow.
# Intended usage: source this file so exports persist.

# Do not enable nounset here; this script is sourced into an interactive shell.

SCRIPT_PATH="${(%):-%N}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
source "$SCRIPT_DIR/dotnet-env-common.zsh"

before_java_home="${JAVA_HOME:-}"
before_java_ver="$(__dotnetenv_java_version_line)"
before_developer_dir="${DEVELOPER_DIR:-}"
before_xcode_select="$(__dotnetenv_xcode_select_path)"
before_xcodebuild="$(__dotnetenv_xcodebuild_version_line)"
before_dotnet="$(__dotnetenv_dotnet_version_line)"

select_xcode=1
do_dotnet_move=1
do_cleanup=1
do_workload_restore=1
do_restore=1
xcode_default_version="16.4"
xcode_behavior="default" # default | set | derive | clear
xcode_set_version=""
while (( $# > 0 )); do
  case "$1" in
    --help|-h)
      __dotnetenv_usage
      return 0 2>/dev/null || exit 0
      ;;
    --set-xcode)
      if [[ "$xcode_behavior" == "derive" ]]; then
        __dotnetenv_die "Cannot combine --set-xcode and --derive-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      if [[ "$xcode_behavior" == "clear" ]]; then
        __dotnetenv_die "Cannot combine --set-xcode and --clear-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi

      xcode_behavior="set"
      ver="$xcode_default_version"
      if (( $# >= 2 )) && [[ "${2:-}" != --* ]]; then
        ver="$2"
        shift 2
      else
        shift 1
      fi

      xcode_set_version="$ver"
      continue
      ;;
    --set-xcode=*)
      if [[ "$xcode_behavior" == "derive" ]]; then
        __dotnetenv_die "Cannot combine --set-xcode and --derive-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      if [[ "$xcode_behavior" == "clear" ]]; then
        __dotnetenv_die "Cannot combine --set-xcode and --clear-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi

      xcode_behavior="set"
      ver="${1#*=}"
      [[ -n "${ver:-}" ]] || ver="$xcode_default_version"
      xcode_set_version="$ver"
      shift
      continue
      ;;
    --derive-xcode)
      if [[ "$xcode_behavior" == "set" ]]; then
        __dotnetenv_die "Cannot combine --set-xcode and --derive-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      if [[ "$xcode_behavior" == "clear" ]]; then
        __dotnetenv_die "Cannot combine --derive-xcode and --clear-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      xcode_behavior="derive"
      shift
      continue
      ;;
    --clear-xcode)
      if [[ "$xcode_behavior" == "set" || "$xcode_behavior" == "derive" ]]; then
        __dotnetenv_die "Cannot combine --clear-xcode with other Xcode selection flags"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      xcode_behavior="clear"
      shift
      continue
      ;;

    # Back-compat aliases (deprecated):
    --set-required-xcode)
      if [[ "$xcode_behavior" == "derive" ]]; then
        __dotnetenv_die "Cannot combine --set-required-xcode and --derive-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      if [[ "$xcode_behavior" == "clear" ]]; then
        __dotnetenv_die "Cannot combine --set-required-xcode and --clear-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      xcode_behavior="set"
      shift
      if [[ -z "${1:-}" ]]; then
        __dotnetenv_die "Missing value for --set-required-xcode (expected major.minor)"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      xcode_set_version="$1"
      ;;
    --set-required-xcode=*)
      if [[ "$xcode_behavior" == "derive" ]]; then
        __dotnetenv_die "Cannot combine --set-required-xcode and --derive-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      if [[ "$xcode_behavior" == "clear" ]]; then
        __dotnetenv_die "Cannot combine --set-required-xcode and --clear-xcode"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      xcode_behavior="set"
      xcode_set_version="${1#*=}"
      ;;
    --clear-required-xcode)
      if [[ "$xcode_behavior" == "set" || "$xcode_behavior" == "derive" ]]; then
        __dotnetenv_die "Cannot combine --clear-required-xcode with other Xcode selection flags"
        __dotnetenv_usage
        return 1 2>/dev/null || exit 1
      fi
      xcode_behavior="clear"
      ;;
    --select-xcode)
      select_xcode=1
      ;;
    --no-select-xcode)
      select_xcode=0
      ;;
    --no-dotnet-move)
      do_dotnet_move=0
      ;;
    --no-cleanup)
      do_cleanup=0
      ;;
    --no-workload-restore)
      do_workload_restore=0
      ;;
    --restore)
      do_restore=1
      ;;
    --no-restore)
      do_restore=0
      ;;
    *)
      __dotnetenv_die "Unknown argument: $1"
      __dotnetenv_usage
      return 1 2>/dev/null || exit 1
      ;;
  esac
  shift
done

# Apply Xcode selection defaults for dotnet9.
case "$xcode_behavior" in
  default)
    export DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET9="$xcode_default_version"
    export DOTNETENV_FORCE_XCODE_AUTO=1
    ;;
  set)
    export DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET9="${xcode_set_version:-$xcode_default_version}"
    export DOTNETENV_FORCE_XCODE_AUTO=1
    ;;
  derive)
    unset DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET9
    export DOTNETENV_FORCE_XCODE_AUTO=1
    ;;
  clear)
    unset DOTNETENV_REQUIRED_XCODE_VERSION_DOTNET9
    unset DOTNETENV_FORCE_XCODE_AUTO
    ;;
esac

if [[ "$do_dotnet_move" == "1" ]]; then
  __dotnetenv_disable_dotnet10 || return 1
fi
__dotnetenv_apply "dotnet9" "$select_xcode" "$(pwd)"

if [[ "$do_cleanup" == "1" ]]; then
  __dotnetenv_repo_cleanup "$(pwd)" "$do_workload_restore" "$do_restore" || return 1
fi

__dotnetenv_print_run_summary \
  "dotnet9" \
  "$select_xcode" \
  "$do_dotnet_move" \
  "$do_cleanup" \
  "$do_workload_restore" \
  "$do_restore" \
  "$before_java_home" \
  "$before_java_ver" \
  "$before_developer_dir" \
  "$before_xcode_select" \
  "$before_xcodebuild" \
  "$before_dotnet"
