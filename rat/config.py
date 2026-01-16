"""Configuration management for RAT."""

import json
from pathlib import Path
from dataclasses import dataclass, asdict, field
from typing import Dict, Optional

CONFIG_DIR = Path.home() / ".config" / "rat"
CONFIG_FILE = CONFIG_DIR / "hosts.json"


DEFAULT_PASSWORD = "ubuntu123!"


@dataclass
class Host:
    """Represents a remote host configuration for RAT connections."""

    name: str
    zrok_token: str
    ssh_user: str
    ssh_key: str = ""
    ssh_password: str = DEFAULT_PASSWORD
    ports: dict = field(default_factory=lambda: {"ssh": 2222, "vnc": 5901, "remote_vnc": 5901})

    @property
    def ssh_port(self) -> int:
        """Get the local SSH port."""
        return self.ports.get("ssh", 2222)

    @property
    def vnc_port(self) -> int:
        """Get the local VNC port."""
        return self.ports.get("vnc", 5901)

    @property
    def remote_vnc_port(self) -> int:
        """Get the remote VNC port."""
        return self.ports.get("remote_vnc", 5901)

    def to_dict(self) -> dict:
        """Convert host to dictionary for JSON serialization."""
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Host":
        """Create a Host instance from a dictionary."""
        # Handle legacy format with separate port fields
        if "ssh_port" in data and "ports" not in data:
            data["ports"] = {
                "ssh": data.pop("ssh_port", 2222),
                "vnc": data.pop("vnc_port", 5901),
                "remote_vnc": data.pop("remote_vnc_port", 5901),
            }
        return cls(**data)


def ensure_config_dir():
    """Ensure config directory exists."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def load_hosts() -> Dict[str, Host]:
    """Load hosts from config file."""
    ensure_config_dir()
    if not CONFIG_FILE.exists():
        return {}

    with open(CONFIG_FILE, encoding="utf-8") as file:
        data = json.load(file)

    return {name: Host.from_dict(h) for name, h in data.items()}


def save_hosts(hosts: Dict[str, Host]):
    """Save hosts to config file."""
    ensure_config_dir()
    data = {name: h.to_dict() for name, h in hosts.items()}

    with open(CONFIG_FILE, "w", encoding="utf-8") as file:
        json.dump(data, file, indent=2)


def get_host(name: str) -> Optional[Host]:
    """Get a host by name."""
    hosts = load_hosts()
    return hosts.get(name)


def add_host(host: Host):
    """Add or update a host."""
    hosts = load_hosts()
    hosts[host.name] = host
    save_hosts(hosts)


def remove_host(name: str) -> bool:
    """Remove a host by name."""
    hosts = load_hosts()
    if name in hosts:
        del hosts[name]
        save_hosts(hosts)
        return True
    return False


def list_hosts() -> Dict[str, Host]:
    """List all hosts."""
    return load_hosts()


def build_ssh_args(host: Host, extra_args: list = None, ssh_flags: list = None) -> tuple:
    """
    Build SSH command arguments for a host.

    Args:
        host: Host configuration
        extra_args: Arguments to append after the host (e.g., remote commands)
        ssh_flags: SSH flags to insert before connection options (e.g., -N, -L)

    Returns a tuple of (executable, args_list) for use with os.execvp or subprocess.
    """
    extra = extra_args or []
    flags = ssh_flags or []
    connection_args = [
        "-o",
        "StrictHostKeyChecking=no",
        "-p",
        str(host.ssh_port),
        f"{host.ssh_user}@localhost",
    ]

    if host.ssh_key:
        args = ["ssh"] + flags + ["-i", host.ssh_key] + connection_args + extra
        return ("ssh", args)

    args = ["sshpass", "-p", host.ssh_password, "ssh"] + flags + connection_args + extra
    return ("sshpass", args)
