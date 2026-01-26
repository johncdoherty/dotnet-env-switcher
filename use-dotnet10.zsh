#!/usr/bin/env zsh

# Switch shell toolchain to match the repo's .NET 10 workflow.
# Intended usage: source this file so exports persist.

# Do not enable nounset here; this script is sourced into an interactive shell.

SCRIPT_PATH="${(%):-%N}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
source "$SCRIPT_DIR/dotnet-env-common.zsh"

select_xcode=1
do_dotnet_move=1
do_cleanup=1
do_workload_restore=1
do_restore=1
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      __dotnetenv_usage
      return 0 2>/dev/null || exit 0
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
      __dotnetenv_die "Unknown argument: $arg"
      __dotnetenv_usage
      return 1 2>/dev/null || exit 1
      ;;
  esac
done

if [[ "$do_dotnet_move" == "1" ]]; then
  __dotnetenv_enable_dotnet10 || return 1
fi
__dotnetenv_apply "dotnet10" "$select_xcode" "$(pwd)"

if [[ "$do_cleanup" == "1" ]]; then
  __dotnetenv_repo_cleanup "$(pwd)" "$do_workload_restore" "$do_restore" || return 1
fi
