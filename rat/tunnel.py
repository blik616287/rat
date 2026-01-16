"""Tunnel management for RAT."""

import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Optional, List

from .config import Host, build_ssh_args

PID_DIR = Path.home() / ".config" / "rat" / "pids"


def ensure_pid_dir():
    """Ensure PID directory exists."""
    PID_DIR.mkdir(parents=True, exist_ok=True)


def get_pid_file(host_name: str, tunnel_type: str) -> Path:
    """Get PID file path for a tunnel."""
    return PID_DIR / f"{host_name}_{tunnel_type}.pid"


def is_process_running(pid: int) -> bool:
    """Check if a process is running."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def get_tunnel_pid(host_name: str, tunnel_type: str) -> Optional[int]:
    """Get PID of running tunnel."""
    pid_file = get_pid_file(host_name, tunnel_type)
    if not pid_file.exists():
        return None

    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
        if is_process_running(pid):
            return pid
        pid_file.unlink()
        return None
    except (ValueError, FileNotFoundError):
        return None


def start_daemon_process(cmd: List[str]) -> Optional[int]:
    """Start a daemon process and return its PID if successful."""
    with subprocess.Popen(
        cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True
    ) as proc:
        # Wait a bit for it to start
        time.sleep(2)

        if proc.poll() is None:
            # Process is still running (daemon started successfully)
            return proc.pid
        # Process exited (failed to start)
        return None


def start_zrok_access(host: Host) -> bool:
    """Start zrok access tunnel for a host."""
    ensure_pid_dir()

    # Check if already running
    pid = get_tunnel_pid(host.name, "zrok")
    if pid:
        print(f"Zrok access already running (PID: {pid})")
        return True

    print(f"Starting zrok access for {host.zrok_token}...")

    cmd = [
        "zrok",
        "access",
        "private",
        "--headless",
        "--bind",
        f"127.0.0.1:{host.ssh_port}",
        host.zrok_token,
    ]

    pid = start_daemon_process(cmd)
    if pid:
        pid_file = get_pid_file(host.name, "zrok")
        pid_file.write_text(str(pid), encoding="utf-8")
        print(f"Zrok access started on localhost:{host.ssh_port}")
        return True

    print("Failed to start zrok access")
    return False


def stop_zrok_access(host: Host) -> bool:
    """Stop zrok access tunnel."""
    pid = get_tunnel_pid(host.name, "zrok")
    if not pid:
        print("No zrok access running")
        return False

    print(f"Stopping zrok access (PID: {pid})...")
    try:
        os.kill(pid, signal.SIGTERM)
        get_pid_file(host.name, "zrok").unlink(missing_ok=True)
        print("Zrok access stopped")
        return True
    except OSError as err:
        print(f"Error stopping zrok access: {err}")
        return False


def start_vnc_tunnel(host: Host) -> bool:
    """Start VNC tunnel over SSH."""
    ensure_pid_dir()

    # Check if already running
    pid = get_tunnel_pid(host.name, "vnc")
    if pid:
        print(f"VNC tunnel already running (PID: {pid})")
        return True

    print("Starting VNC tunnel...")

    # Build SSH tunnel command with port forwarding
    tunnel_flags = ["-N", "-L", f"{host.vnc_port}:localhost:{host.remote_vnc_port}"]
    _, cmd = build_ssh_args(host, ssh_flags=tunnel_flags)

    pid = start_daemon_process(cmd)
    if pid:
        pid_file = get_pid_file(host.name, "vnc")
        pid_file.write_text(str(pid), encoding="utf-8")
        print(f"VNC tunnel established on localhost:{host.vnc_port}")
        return True

    print("Failed to establish VNC tunnel")
    return False


def stop_vnc_tunnel(host: Host) -> bool:
    """Stop VNC tunnel."""
    pid = get_tunnel_pid(host.name, "vnc")
    if not pid:
        print("No VNC tunnel running")
        return False

    print(f"Stopping VNC tunnel (PID: {pid})...")
    try:
        os.kill(pid, signal.SIGTERM)
        get_pid_file(host.name, "vnc").unlink(missing_ok=True)
        print("VNC tunnel stopped")
        return True
    except OSError as err:
        print(f"Error stopping VNC tunnel: {err}")
        return False


def stop_all_tunnels(host: Host):
    """Stop all tunnels for a host."""
    stop_vnc_tunnel(host)
    stop_zrok_access(host)
