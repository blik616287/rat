# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RAT (Remote Access Tool) is a Python CLI for SSH and VNC access to remote hosts through zrok tunnels. It manages local TCP tunnels via zrok and optional SSH port forwarding for VNC connections.

## Build/Test Commands

```bash
make install          # pip install -e .
make install-dev      # Install with dev dependencies
make test             # Run pytest
make coverage         # Run tests with coverage (95% minimum required)
make lint             # Run pylint (expects 10.0/10)
make format           # Format code with black (line-length 100)
make check            # Run format-check and lint
```

Run a single test:
```bash
pytest tests/test_cli.py::TestCmdSsh -v
```

## Architecture

```
User Command → cli.py → config.py → tunnel.py → External (zrok, ssh, remmina)
```

**Three-layer design:**

1. **CLI Layer** (`rat/cli.py`) - Entry point `main()`, 7 subcommands (ssh, vnc, add, remove, list, status, stop)

2. **Configuration Layer** (`rat/config.py`) - `Host` dataclass, JSON persistence at `~/.config/rat/hosts.json`, SSH command builder supporting key and password auth

3. **Tunnel Layer** (`rat/tunnel.py`) - zrok access tunnel management, VNC SSH port forwarding, PID tracking in `~/.config/rat/pids/`

**Connection flow for VNC:**
```
Local → zrok tunnel → Remote SSH:22 → SSH port forward → Remote VNC:5901
```

## Code Quality Requirements

- Test coverage: 100% (minimum 95%)
- Pylint: 10.0/10 score
- Black formatting: 100 char line length

## Key Patterns

- **Authentication**: Key-based uses `ssh -i <key>`, password-based uses `sshpass -p <password> ssh`
- **PID files**: `~/.config/rat/pids/{hostname}_{tunnel_type}.pid` - validates process alive before reuse
- **Port defaults**: SSH=2222, VNC=5901
- **Testing**: pytest with fixtures for sample hosts, mock external dependencies with `mock.patch`

## External Dependencies

Runtime: `zrok`, `sshpass`, `remmina` (optional for VNC viewing)
