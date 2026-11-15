# jd-org-task: `ot`

Org tasks from the shell. `ot` adds, lists and changes TODO headings in an
Org file through a small Emacs, so the file stays plain Org that your own
Emacs, phone apps and other tools read as usual.

```console
$ ot add Renew it --under 11.11 --due fri
97c0ac26  TODO   <2026-11-20 Fri>  11.11       Renew it
$ ot add Book flights --under W0011 --state NEXT
$ ot ls
97c0ac26  TODO   <2026-11-20 Fri>  11.11       Renew it
51b0cce4  NEXT                     W0011       Book flights
$ ot done 97c0
$ ot ls --json | jq '.[].title'
"Book flights"
```

It was made for a [Johnny.Decimal](https://johnnydecimal.com) JDex kept in
Org, so `--under` takes a heading's number, but it works on any Org file.

## Commands

| Command | What it does |
| --- | --- |
| `ot add TITLE... [--under ID] [--due WHEN] [--state STATE]` | add a task under a heading, or in the inbox |
| `ot ls [--under ID] [--state STATE] [--all]` | list open tasks (or one state, or all) |
| `ot set TASK STATE` | change a task's state |
| `ot done TASK` | mark it done |
| `ot where TASK` | print `FILE:LINE` |
| `ot open TASK` | open it in your editor (`$OT_EDITOR`, else `emacsclient -n`) |
| `ot daemon` / `ot stop` | run ot's Emacs in the foreground / stop it |

`--file FILE` and `--json` work with any command.

- **`ID`** names a heading by its `CUSTOM_ID`, or by the number its title
  starts with. For example, use `11.11` for an ID, or `W0011` for a work
  package. `W0011~11.11` also checks that the work package belongs to 11.11.
- **`TASK`** is the start of a task's id, as `ot ls` prints it. Each task
  gets an Org `ID` property (a UUID) when it's added, so its id doesn't
  change when you edit or move it.
- **`WHEN`** is anything Org's date prompt reads, such as `fri`, `+2w` or
  `2026-12-01`.
- **States** are the file's own `#+TODO:` line. Without one, `ot` uses
  `TODO NEXT WAIT | DONE CANCELLED`. Add that line to the file so your own
  Emacs agrees:

  ```org
  #+TODO: TODO NEXT WAIT | DONE CANCELLED
  ```

## How it runs

Each command runs a small Emacs started with `-Q`, which loads Org and
`ot.el` but never your own config. `ot` tries these in order:

1. **A daemon on `$OT_SOCKET`** (named `ot` by default). If none is running,
   `ot` starts one, and it keeps running after that. Each command then
   takes a few milliseconds, and the daemon uses about 70 MB of memory.
2. **`emacs -Q --batch`**, if no daemon can be used, or if `OT_DAEMON=0` is
   set. This takes about 0.3 s per command.

The daemon reloads the file whenever it changed on disk and saves after
every change, so it's safe to edit the same file in your own Emacs.

| Variable | Default | Meaning |
| --- | --- | --- |
| `OT_FILE` | `~/org/tasks.org` | the Org file |
| `OT_INBOX` | `Inbox` | where `ot add` puts a task without `--under`: a `CUSTOM_ID`, number or title. It's made at the end of the file if missing. For a JDex, `11.01` is a natural choice. |
| `OT_SOCKET` | `ot` | the daemon's socket: a name, or an absolute path |
| `OT_DAEMON` | `auto` | `0` to always use `--batch` |
| `OT_EDITOR` | `emacsclient -n` | what `ot open` runs, with `+LINE FILE` |

## Install

```sh
nix profile install github:bahiamovementcenter/jd-org-task   # or the overlay: pkgs.ot
```

### As a service

On NixOS 25.11 or later, a
[modular service](https://nixos.org/manual/nixos/unstable/#modular-services)
can keep the daemon running from boot:

```nix
{ pkgs, ... }:
{
  system.services.ot = {
    imports = [ pkgs.ot.services.default ];
    ot.user = "ash"; # the user whose files it edits
  };
  environment.sessionVariables.OT_SOCKET = "/run/ot/server";
}
```

Modular services are new and still changing, and NixOS has only system
services so far, which is why the module needs `ot.user` and a fixed socket
path. When per-user services and other service managers (such as launchd
on macOS) support modular services, the same module should work there.
Without the service, `ot` starts its own daemon, so the service is optional.

## Development

```sh
nix develop
nix flake check   # tests/test.sh in real Emacs, with --batch and a daemon;
                  # shellcheck; the service's systemd unit
nix fmt
```

`lisp/ot.el` holds the logic. `bin/ot` only chooses daemon or batch, and
passes the arguments along.

## Licence

Copyright © 2026 Ash. Licensed under the
[GNU Affero General Public License v3.0 only](LICENSE) (`AGPL-3.0-only`).
