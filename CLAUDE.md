# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is RAT?

RAT (Remote Access Tool) is a Python CLI (`rat`, entry point `rat.cli:main`) for reaching remote hosts over SSH and VNC through zrok private shares. It has zero runtime dependencies and shells out to `zrok`, `ssh`, `sshpass`, and `remmina`. Host config persists in `~/.config/rat/hosts.json`; running tunnels are tracked by PID files in `~/.config/rat/pids/`.

## Development Commands

```bash
make install-dev    # Editable install + pytest, pytest-cov, black, pylint
make test           # pytest tests/ -v
make coverage       # Enforces 95% minimum (branch coverage enabled)
make lint           # pylint rat/ — must score 10.0/10
make format         # black rat/ tests/ --line-length 100
make check          # black --check + lint (run `make format` first if it fails)
```

Single test file / class / case:
```bash
python -m pytest tests/test_cli.py -v
python -m pytest tests/test_cli.py::TestCmdSsh -v
python -m pytest tests/test_cli.py::TestCmdSsh::test_cmd_ssh_with_key -v
```

Code must stay compatible with Python 3.8 (`requires-python >=3.8`, black targets py38), so avoid newer syntax such as `X | Y` types or `match`.

## Architecture

- **`rat/cli.py`**: argparse subcommands (`ssh`, `vnc`, `add`, `remove`, `list`, `status`, `stop`), each a `cmd_*()` function wired up in `setup_parsers()` via `set_defaults(func=...)`.
- **`rat/config.py`**: the `Host` dataclass, JSON persistence, and `build_ssh_args()`.
- **`rat/tunnel.py`**: background-process lifecycle for the zrok access tunnel and the VNC port-forward.

Connection flow: `zrok access private --headless --bind 127.0.0.1:<ssh_port> <token>` exposes the remote SSH server on localhost. All SSH, including the VNC tunnel, then goes to `<user>@localhost -p <ssh_port>`. VNC is an `ssh -N -L <vnc_port>:localhost:<remote_vnc_port>` that runs *through* the zrok tunnel, so zrok must be started first. Remmina is then launched against `vnc://localhost:<vnc_port>`.

Non-obvious behaviors:
- `cmd_ssh` uses `os.execvp`, which replaces the `rat` process with ssh/sshpass. Nothing after that call runs.
- `build_ssh_args(host, extra_args, ssh_flags)` returns an `(executable, argv)` tuple. Key auth gives `ssh -i ...`. Without a key it gives `sshpass -p <password> ssh ...`. `ssh_flags` go before the connection options and `extra_args` (remote command) go after the host.
- Every host is reached as `localhost:<port>`, so `build_ssh_args` always sets `StrictHostKeyChecking=no` **and** `UserKnownHostsFile=/dev/null`. Without these, a local port reused by a different host trips a known_hosts mismatch. zrok is what authenticates the far end, not the host key. Don't remove them.
- When there's a remote command (`extra_args`), `build_ssh_args` adds `-n` so ssh doesn't swallow the stdin of a shell script that calls `rat`. Setting the env var `RAT_SSH_STDIN` turns this off so input can be piped to the remote command.
- `start_daemon_process()` runs `Popen(..., start_new_session=True)`, sleeps 2s, and counts success as "still running" (`poll() is None`). Its PID is written to `pids/<host>_<zrok|vnc>.pid`.
- `get_tunnel_pid()` checks liveness with `os.kill(pid, 0)` and deletes stale PID files as a side effect.
- Ports are stored in a nested `ports` dict (`ssh`, `vnc`, `remote_vnc`) and read through `Host` properties. `Host.from_dict()` migrates the legacy flat `ssh_port`/`vnc_port`/`remote_vnc_port` fields.

## Testing Conventions

- Everything external is mocked: `subprocess.Popen`, `os.execvp`, `os.kill`, `time.sleep`. No real processes or network.
- Filesystem isolation works by patching the module-level path constants to temp dirs: `rat.config.CONFIG_DIR`, `rat.config.CONFIG_FILE`, `rat.tunnel.PID_DIR`.
- Patch functions where they are looked up, not where they are defined. For example, patch `rat.cli.get_host` and `rat.cli.start_zrok_access` for CLI tests, and `rat.tunnel.time.sleep` and `rat.tunnel.subprocess.Popen` for tunnel tests.

## Remote Host Setup

`agent/setup-zrok-jumphost.sh` bootstraps a remote host. It installs zrok, TigerVNC and OpenSSH, enables SSH password auth, and creates the systemd services `ssh`, `vncserver@1` and `zrok-ssh` (a reserved zrok share). Usage: `<zrok-enable-token> [share-name=jumphostssh] [user-password=ubuntu123] [vnc-password=ubuntu123]`. The README publishes this script as `setup-zrok.sh` on S3. Its defaults (user `ubuntu`, password `ubuntu123`, share `jumphostssh`) match `rat add`'s defaults.

- `agent/setup-zrok-ssh.sh <token> [share-name]` is the SSH-only variant (no VNC). It assumes SSH and the user already exist.
- `agent/zrok-health-check.sh <token> <share-name>` is an auto-repair job meant for cron or a systemd timer. It re-enables zrok, re-reserves the share (`localhost:22`, `tcpTunnel`) and restarts `zrok-ssh.service`. It is deliberately **fail-closed**: it only runs `zrok disable`/re-enable on a genuine auth error (`INVALID_AUTH`/`UNAUTHORIZED`). On any other `zrok overview` failure, such as DNS or 5xx, it exits 0 without touching anything, and it never releases a share after a failed reserve. A release or disable would permanently destroy the share or environment, so keep that behavior when editing it.
- `agent/setup-zrok-ssh-macos.sh` and `agent/zrok-health-check-macos.sh` are the macOS (launchd) ports of those two scripts. They pin zrok v1.1.13, because zrok v2 removed `reserve`/`share reserved` and renamed the binary to `zrok2`. They use the LaunchDaemons `io.rat.zrok-ssh` (KeepAlive, runs as the user) and `io.rat.zrok-health` (runs as root every 300s and calls zrok as the owner of the env file via `sudo -u`). zrok calls are wrapped in BSD `script -q /dev/null` for a pty. Logs go to `~/Library/Logs/rat/`. A fix to the fail-closed logic in one health check usually belongs in the others too: the Linux standalone, the copy embedded in `setup-zrok-ssh.sh`/`setup-zrok-jumphost.sh`, and the macOS one.

## Windows 11 Client (SSH only)

The `rat` CLI is Linux-only. For Windows 11 clients the `agent/` directory ships three PowerShell scripts that cover SSH only (no VNC):

- **`agent/setup-zrok-client-windows.ps1`** — installs the client prerequisites (OpenSSH client via `Add-WindowsCapability`; zrok binary downloaded from the latest `openziti/zrok` GitHub release into `%LOCALAPPDATA%\zrok` and added to the user PATH), optionally runs `zrok enable <token>`, and prints the two-terminal connect flow. Params: `-EnableToken`, `-InstallDir`, `-ShareName`, `-SshUser`, `-SshPort`.
- **`agent/rat-ssh.ps1`** — the Windows equivalent of `rat ssh` in one command: opens a `zrok access private` tunnel on the local port, waits for it to bind, runs `ssh` to `localhost:<port>`, and tears the tunnel down when the session ends. If the port is already bound it reuses that tunnel and leaves it running. Password auth uses OpenSSH's interactive prompt (no sshpass on Windows); `-IdentityFile` selects key auth. Required param `-ShareName`; optional `-SshUser`, `-SshPort`, `-IdentityFile`, `-TimeoutSeconds`, and a trailing remote command.
- **`agent/healthcheck-zrok-client.ps1`** — end-to-end check of the SSH path: zrok installed and enabled, OpenSSH client present, a temporary `zrok access private` tunnel binds the local port, the port accepts TCP, and the remote SSH server returns an `SSH-` banner. Banner-only, so no credentials and no changes to the remote host; the temp tunnel is always torn down. Exits 0 only if every check passes (CI-friendly). Required param `-ShareName`; optional `-SshPort`, `-TimeoutSeconds`.

Since there is no `rat` process on Windows, `rat-ssh.ps1` plays that role; under the hood it mirrors `rat ssh` (`zrok access private --bind 127.0.0.1:<port> <share>` then `ssh -p <port> <user>@localhost`). These scripts are PowerShell and are not exercised by the pytest suite.
