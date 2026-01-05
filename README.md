# MAUI .NET9.0/NET10.0 Environment Toolchain Switcher

This repo provides `zsh` helpers for MAUI app developers working on the .NET 9 and 10 solutions in parallel, and require the ability to jump between them and have their environment function properly.

Purpose:

- Quickly switch your *current terminal session* between the repo’s “.NET 9” and “.NET 10” toolchain expectations (JDK + Xcode selection)
- Reduce “it builds on my machine” drift by keeping `JAVA_HOME`, `DEVELOPER_DIR`, and (optionally) the system-wide `xcode-select` aligned
- Optionally perform a safe-ish local cleanup (`dotnet clean`, `dotnet workload restore`, delete `bin/`/`obj/`, delete `*.csproj.user`) in the directory you run it from

Non-goals:

- This is **not** a general-purpose .NET version manager (it does not install SDKs). It assumes the repo’s SDK/workload versions are defined in `global.json` and installed/restorable via `dotnet workload restore`.
- This does **not** permanently modify your shell configuration; it’s meant to be run via `source` so environment variables apply to the current shell.

- `use-dotnet9.zsh`: sets `JAVA_HOME` to JDK 17 and `DEVELOPER_DIR` to Xcode 16.4
- `use-dotnet10.zsh`: sets `JAVA_HOME` to JDK 21 and `DEVELOPER_DIR` to Xcode 26.1 (override as needed)

Additionally:

- `use-dotnet9.zsh` disables discovery of `.NET 10` SDKs by moving `10.*` folders out of the dotnet install root.
- `use-dotnet10.zsh` re-enables `.NET 10` SDKs by moving those `10.*` folders back.

This is specifically to work around tooling/debugger behavior that breaks for .NET 9 apps when .NET 10 is installed.

## TL;DR

Add this to your `~/.zshrc` (or `~/.zprofile` if you prefer login shells), restart your terminal, then run `use-dotnet9` / `use-dotnet10`:

```zsh
export DOTNET_ENV_SWITCHER_DIR="$HOME/source/dotnet-env-switcher"
use-dotnet9()  { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet9.zsh"  "$@"; }
use-dotnet10() { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet10.zsh" "$@"; }

# Optional but recommended - update for your actual path and file name
export DOTNET9_XCODE_APP="/Applications/Xcode_16.4.app"
export DOTNET10_XCODE_APP="/Applications/Xcode_26.1.app"  
```

Common usage (Typically run from a .NET solution folder in VSCode):

- `use-dotnet9`
- `use-dotnet10 --no-select-xcode` (avoids `sudo xcode-select ...`)

## Install / setup

These scripts are meant to be “installed” by putting the folder somewhere stable on your machine and adding a couple functions to your shell profile so you can run them from anywhere.

### Prerequisites

- macOS + `zsh`
- JDK 17 and JDK 21 installed (the scripts resolve these via `/usr/libexec/java_home -v <version>`)
	- Quick check:
		- `/usr/libexec/java_home -v 17`
		- `/usr/libexec/java_home -v 21`
- Xcode installed for each toolchain (defaults are below; you can override them)
- `.NET SDK` installed as pinned by the repo’s `global.json`
	- The repo expects an exact SDK match (because `rollForward` is disabled).
	- Quick check from the repo root: `dotnet --version`
	- If your machine has multiple SDKs: `dotnet --list-sdks`
- `.NET MAUI` workloads are expected to be restored (not hand-installed) using the workload version pinned by `global.json`
	- Expected workflow is to run `dotnet workload restore` from the repo root (or let these scripts do it as part of the default cleanup).
	- These scripts run `dotnet workload restore` automatically unless you pass `--no-workload-restore` or `--no-cleanup`.
	- If workloads are installed system-wide, `dotnet workload restore` may prompt for elevation; the scripts will retry with `sudo` when dotnet reports inadequate permissions.

#### Example `global.json`

The repo uses `global.json` to pin both the SDK and the MAUI workload “manifest set” via `workloadVersion`.

Example for .NET 9:

```json
{
	"sdk": {
		"version": "9.0.305",
		"workloadVersion": "9.0.305",
		"rollForward": "disable",
		"allowPrerelease": false
	}
}
```

Example template for .NET 10 (fill in the exact versions your repo pins):

```json
{
	"sdk": {
		"version": "10.0.xxx",
		"workloadVersion": "10.0.xxx",
		"rollForward": "disable",
		"allowPrerelease": false
	}
}
```

### Add convenience functions

Add this to your `~/.zshrc` (or `~/.zprofile` if you prefer login shells), adjusting the path to wherever you keep this folder:

```zsh
export DOTNET_ENV_SWITCHER_DIR="$HOME/source/dotnet-env-switcher"

use-dotnet9()  { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet9.zsh"  "$@"; }
use-dotnet10() { source "$DOTNET_ENV_SWITCHER_DIR/use-dotnet10.zsh" "$@"; }
```

Then either restart your terminal, or run `source ~/.zshrc`.

### Configure Xcode app paths (optional)

If your Xcode apps aren’t at the defaults, set these in your `~/.zshrc`:

- `export DOTNET9_XCODE_APP="/Applications/Xcode_16.4.app"`
- `export DOTNET10_XCODE_APP="/Applications/Xcode_26.1.app"`  (or your actual path)

(Use whatever names you have installed.)

## Why `source`?

Environment variables (`JAVA_HOME`, `DEVELOPER_DIR`, `PATH`) must be set in the current shell. That means you should run:

- `source /path/to/scripts/use-dotnet9.zsh`
- `source /path/to/scripts/use-dotnet10.zsh`

If you execute the script normally, exports won’t persist in your current shell.

## What it changes

On success, it prints a small status block showing the chosen toolchain:

- `JAVA_HOME` (and ensures `$JAVA_HOME/bin` is first in `PATH`)
- `DEVELOPER_DIR`

By default it also:

- Runs `sudo xcode-select -s "$DEVELOPER_DIR"` (system-wide)
- Performs a cleanup in the *current directory*:
	- Deletes `*.csproj.user`
	- Runs `dotnet clean` on the first `*.sln` in the current directory (if any)
	- Runs `dotnet workload restore` on the first `*.sln` in the current directory (if any)
		- Retries with `sudo` if dotnet reports inadequate permissions
	- Deletes all `bin/` and `obj/` folders recursively (skipping `.git/.vs/.idea/node_modules`)

And it manages .NET 10 SDK visibility:

- When switching to .NET 9: moves `/usr/local/share/dotnet/sdk/10.*` and `/usr/local/share/dotnet/sdk-manifests/10.*` into a disabled storage directory.
- When switching to .NET 10: moves those folders back.
	- This may prompt for `sudo` depending on permissions.

## Usage

Once you’ve added the functions in your shell profile:

- `use-dotnet9`
- `use-dotnet10`

Flags:

- `--help` / `-h`: print usage
- `--no-select-xcode`: do not run `sudo xcode-select -s ...`
- `--no-dotnet-move`: do not move `.NET 10` SDK/manifests folders (only switches JDK/Xcode)
- `--no-cleanup`: skip repo cleanup (no deletes, no `dotnet clean`, no workload restore)
- `--no-workload-restore`: run cleanup but skip `dotnet workload restore`

### Optional configuration for .NET folder moving

If your dotnet install root is not `/usr/local/share/dotnet`, or you want to control where the moved folders are stored:

- `export DOTNETENV_DOTNET_ROOT="/usr/local/share/dotnet"`
- `export DOTNETENV_DISABLED_DIR="/usr/local/share/dotnet/.env-switcher-disabled"`

## Quick verification

After switching, these should all reflect the expected environment:

- `echo $JAVA_HOME`
- `echo $DEVELOPER_DIR`
- `java -version`
- `xcodebuild -version`

If you’re using VS Code, the most reliable flow is:

- Run `use-dotnet9` / `use-dotnet10` in a terminal
- Launch VS Code from that same terminal (or keep the default system-wide `xcode-select` behavior)
