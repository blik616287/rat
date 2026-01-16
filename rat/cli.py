#!/usr/bin/env python3
"""RAT - Remote Access Tool CLI."""
import argparse
import os
import subprocess
import sys
from pathlib import Path

from . import __version__
from .config import (
    Host,
    get_host,
    add_host,
    remove_host,
    list_hosts,
    build_ssh_args,
    DEFAULT_PASSWORD,
)
from .tunnel import start_zrok_access, start_vnc_tunnel, stop_all_tunnels, get_tunnel_pid


def cmd_ssh(args):
    """SSH to a host via zrok tunnel."""
    host = get_host(args.name)
    if not host:
        print(f"Error: Host '{args.name}' not found")
        print("Use 'rat add' to add a host first")
        sys.exit(1)

    # Start zrok access
    if not start_zrok_access(host):
        sys.exit(1)

    # Build and execute SSH command
    executable, ssh_cmd = build_ssh_args(host, args.command if args.command else None)
    os.execvp(executable, ssh_cmd)


def cmd_vnc(args):
    """Connect via VNC to a host through zrok tunnel."""
    host = get_host(args.name)
    if not host:
        print(f"Error: Host '{args.name}' not found")
        print("Use 'rat add' to add a host first")
        sys.exit(1)

    # Start zrok access
    if not start_zrok_access(host):
        sys.exit(1)

    # Start VNC tunnel
    if not start_vnc_tunnel(host):
        sys.exit(1)

    # Launch VNC viewer
    print("Launching VNC viewer...")
    with subprocess.Popen(
        ["remmina", "-c", f"vnc://localhost:{host.vnc_port}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ):
        pass  # Remmina runs independently


def cmd_add(args):
    """Add a new host configuration."""
    ssh_key = str(Path(args.key).expanduser()) if args.key else ""
    host = Host(
        name=args.name,
        zrok_token=args.token,
        ssh_user=args.user,
        ssh_key=ssh_key,
        ssh_password=args.password,
        ports={"ssh": args.ssh_port, "vnc": args.vnc_port, "remote_vnc": args.remote_vnc_port},
    )
    add_host(host)
    auth_method = f"key ({ssh_key})" if ssh_key else "password"
    print(f"Host '{args.name}' added (auth: {auth_method})")


def cmd_remove(args):
    """Remove a host configuration."""
    if remove_host(args.name):
        print(f"Host '{args.name}' removed")
    else:
        print(f"Host '{args.name}' not found")
        sys.exit(1)


def cmd_list(_args):
    """List all configured hosts."""
    hosts = list_hosts()
    if not hosts:
        print("No hosts configured")
        print("Use 'rat add' to add a host")
        return

    print(f"{'NAME':<15} {'ZROK TOKEN':<20} {'USER':<15} {'STATUS'}")
    print("-" * 70)
    for name, host in hosts.items():
        zrok_pid = get_tunnel_pid(name, "zrok")
        vnc_pid = get_tunnel_pid(name, "vnc")
        status = []
        if zrok_pid:
            status.append(f"zrok:{zrok_pid}")
        if vnc_pid:
            status.append(f"vnc:{vnc_pid}")
        status_str = ", ".join(status) if status else "stopped"
        print(f"{name:<15} {host.zrok_token:<20} {host.ssh_user:<15} {status_str}")


def cmd_status(args):
    """Show detailed status of a host."""
    host = get_host(args.name)
    if not host:
        print(f"Error: Host '{args.name}' not found")
        sys.exit(1)

    print(f"Host: {host.name}")
    print(f"  Zrok token: {host.zrok_token}")
    print(f"  SSH user: {host.ssh_user}")
    if host.ssh_key:
        print(f"  SSH auth: key ({host.ssh_key})")
    else:
        print("  SSH auth: password")
    print(f"  SSH port: {host.ssh_port}")
    print(f"  VNC port: {host.vnc_port}")

    zrok_pid = get_tunnel_pid(host.name, "zrok")
    vnc_pid = get_tunnel_pid(host.name, "vnc")

    zrok_status = f"running (PID: {zrok_pid})" if zrok_pid else "stopped"
    vnc_status = f"running (PID: {vnc_pid})" if vnc_pid else "stopped"
    print(f"  Zrok access: {zrok_status}")
    print(f"  VNC tunnel: {vnc_status}")


def cmd_stop(args):
    """Stop all tunnels for a host."""
    host = get_host(args.name)
    if not host:
        print(f"Error: Host '{args.name}' not found")
        sys.exit(1)

    stop_all_tunnels(host)


def setup_parsers(subparsers):
    """Configure argument subparsers for all commands."""
    # ssh command
    ssh_parser = subparsers.add_parser("ssh", help="SSH to a host")
    ssh_parser.add_argument("name", help="Host name")
    ssh_parser.add_argument("command", nargs="*", help="Command to run (optional)")
    ssh_parser.set_defaults(func=cmd_ssh)

    # vnc command
    vnc_parser = subparsers.add_parser("vnc", help="VNC to a host")
    vnc_parser.add_argument("name", help="Host name")
    vnc_parser.set_defaults(func=cmd_vnc)

    # add command
    add_parser = subparsers.add_parser("add", help="Add a host")
    add_parser.add_argument("name", help="Host name")
    add_parser.add_argument("-t", "--token", required=True, help="Zrok share token")
    add_parser.add_argument("-u", "--user", default="ubuntu", help="SSH user (default: ubuntu)")
    add_parser.add_argument(
        "-k", "--key", help="SSH key path (if not provided, uses password auth)"
    )
    add_parser.add_argument(
        "-p",
        "--password",
        default=DEFAULT_PASSWORD,
        help=f"SSH password (default: {DEFAULT_PASSWORD})",
    )
    add_parser.add_argument(
        "--ssh-port", type=int, default=2222, help="Local SSH port (default: 2222)"
    )
    add_parser.add_argument(
        "--vnc-port", type=int, default=5901, help="Local VNC port (default: 5901)"
    )
    add_parser.add_argument(
        "--remote-vnc-port", type=int, default=5901, help="Remote VNC port (default: 5901)"
    )
    add_parser.set_defaults(func=cmd_add)

    # remove command
    remove_parser = subparsers.add_parser("remove", help="Remove a host")
    remove_parser.add_argument("name", help="Host name")
    remove_parser.set_defaults(func=cmd_remove)

    # list command
    list_parser = subparsers.add_parser("list", help="List all hosts")
    list_parser.set_defaults(func=cmd_list)

    # status command
    status_parser = subparsers.add_parser("status", help="Show status of a host")
    status_parser.add_argument("name", help="Host name")
    status_parser.set_defaults(func=cmd_status)

    # stop command
    stop_parser = subparsers.add_parser("stop", help="Stop tunnels for a host")
    stop_parser.add_argument("name", help="Host name")
    stop_parser.set_defaults(func=cmd_stop)


def main():
    """Entry point for the RAT CLI."""
    parser = argparse.ArgumentParser(
        prog="rat", description="RAT - Remote Access Tool via zrok tunnels"
    )
    parser.add_argument("-v", "--version", action="version", version=f"%(prog)s {__version__}")

    subparsers = parser.add_subparsers(dest="command", help="Commands")
    setup_parsers(subparsers)

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    args.func(args)


if __name__ == "__main__":
    main()
