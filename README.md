# RAT - Remote Access Tool

A CLI tool for SSH and VNC access to remote hosts via [zrok](https://zrok.io) tunnels.

## Requirements

- Python 3.8 - 3.13
- `zrok` - for tunnel access
- `sshpass` - for password-based SSH authentication
- `remmina` - for VNC viewing (optional)

## Installation

```bash
# Basic installation
pip install -e .

# With development dependencies
pip install -e ".[dev]"
```

## Quick Start

```bash
# Add a host with password auth (simplest)
rat add jumphost -t myzroktoken

# SSH to the host
rat ssh jumphost

# VNC to the host
rat vnc jumphost

# Stop all tunnels
rat stop jumphost
```

## Commands

### `rat add`

Add a new host configuration.

```bash
rat add <name> -t <token> [options]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-t, --token` | Zrok share token (required) | - |
| `-u, --user` | SSH username | `ubuntu` |
| `-k, --key` | SSH key path (uses password auth if not provided) | - |
| `-p, --password` | SSH password | `ubuntu123` |
| `--ssh-port` | Local SSH port | `2222` |
| `--vnc-port` | Local VNC port | `5901` |
| `--remote-vnc-port` | Remote VNC port | `5901` |

**Examples:**

```bash
# Password auth (default password: ubuntu123)
rat add jumphost -t jumphostssh

# Password auth with custom user and password
rat add jumphost -t jumphostssh -u admin -p secretpass

# Key-based auth
rat add jumphost -t jumphostssh -u ubuntu -k ~/.ssh/mykey

# Custom ports
rat add jumphost -t jumphostssh --ssh-port 2223 --vnc-port 5902
```

### `rat remove`

Remove a host configuration.

```bash
rat remove <name>
```

### `rat list`

List all configured hosts and their status.

```bash
rat list
```

Output:
```
NAME            ZROK TOKEN           USER            STATUS
----------------------------------------------------------------------
jumphost        jumphostssh          ubuntu          zrok:12345, vnc:12346
devserver       devtoken             admin           stopped
```

### `rat status`

Show detailed status of a specific host.

```bash
rat status <name>
```

Output:
```
Host: jumphost
  Zrok token: jumphostssh
  SSH user: ubuntu
  SSH auth: password
  SSH port: 2222
  VNC port: 5901
  Zrok access: running (PID: 12345)
  VNC tunnel: running (PID: 12346)
```

### `rat ssh`

SSH to a host. Automatically starts the zrok tunnel if not running.

```bash
rat ssh <name> [command...]
```

**Examples:**

```bash
# Interactive SSH session
rat ssh jumphost

# Run a command
rat ssh jumphost hostname

# Run multiple commands
rat ssh jumphost "ls -la && whoami"
```

### `rat vnc`

Connect via VNC to a host. Starts zrok tunnel and SSH port forward, then launches Remmina.

```bash
rat vnc <name>
```

### `rat stop`

Stop all tunnels (zrok and VNC) for a host.

```bash
rat stop <name>
```

## Configuration

Host configurations are stored in `~/.config/rat/hosts.json`.

PID files for running tunnels are stored in `~/.config/rat/pids/`.

## How It Works

1. **Zrok Access**: RAT uses `zrok access private` to create a local TCP tunnel to the remote host's SSH port via the zrok network.

2. **SSH**: Connects to `localhost:<ssh-port>` which is forwarded through zrok to the remote host.

3. **VNC**: Creates an SSH tunnel (`-L`) through the zrok connection to forward the remote VNC port to a local port, then launches Remmina.

```
[Local] --> [zrok tunnel] --> [Remote SSH:22]
                                    |
                                    v
                              [Remote VNC:5901]
```

## Remote Host Setup

The setup script configures a remote host with zrok, SSH (password auth), and VNC. This is designed for airgapped or semi-airgapped environments where you need a single command to bootstrap everything.

### Prerequisites

1. **Get a zrok account**: Register at https://api-v1.zrok.io
2. **Get your enable token**: After registering, copy your account enable token from the zrok console

### Setup Script Location

The setup script is hosted publicly at:
```
https://sl-public-scripts.s3.us-east-2.amazonaws.com/setup-zrok.sh
```

### Running the Setup

**Script Usage:**
```bash
./setup-zrok.sh <zrok-enable-token> [share-name] [user-password] [vnc-password]
```

| Argument | Description | Default |
|----------|-------------|---------|
| `zrok-enable-token` | Your zrok account enable token (required) | - |
| `share-name` | Unique name for the zrok share | `jumphostssh` |
| `user-password` | Password for the ubuntu user | `ubuntu123` |
| `vnc-password` | Password for VNC access | `ubuntu123` |

**Option 1: Direct execution (if the host has internet access)**

```bash
# With defaults
curl -sSL https://sl-public-scripts.s3.us-east-2.amazonaws.com/setup-zrok.sh | bash -s -- <zrok-enable-token> <share-name>

# With custom passwords
curl -sSL https://sl-public-scripts.s3.us-east-2.amazonaws.com/setup-zrok.sh | bash -s -- <zrok-enable-token> myshare mysshpass myvncpass
```

**Option 2: Download first, then transfer (for airgapped machines)**

On a machine with internet access:
```bash
# Download the script
curl -sSL https://sl-public-scripts.s3.us-east-2.amazonaws.com/setup-zrok.sh -o setup-zrok.sh

# Verify the download
cat setup-zrok.sh
```

Transfer `setup-zrok.sh` to the airgapped machine via USB, SCP through a bastion, or other secure method, then:
```bash
chmod +x setup-zrok.sh
./setup-zrok.sh <zrok-enable-token> <share-name> [user-password] [vnc-password]
```

**Option 3: Copy-paste the script**

If you can't transfer files but have terminal access, you can copy the script content and paste it directly:
```bash
cat > setup-zrok.sh << 'SCRIPT'
# Paste the entire script content here
SCRIPT
chmod +x setup-zrok.sh
./setup-zrok.sh <zrok-enable-token> <share-name> [user-password] [vnc-password]
```

### What the Setup Script Does

1. **Installs packages**: zrok, TigerVNC, OpenSSH server, dbus-x11
2. **Configures SSH**: Enables password authentication, listens on 0.0.0.0
3. **Sets credentials** (configurable via arguments):
   - Ubuntu user password: `ubuntu123` (default)
   - VNC password: `ubuntu123` (default)
4. **Creates systemd services**:
   - `ssh.service` - OpenSSH server
   - `vncserver@1.service` - TigerVNC on display :1
   - `zrok-ssh.service` - Zrok reserved share for SSH
5. **Enables and starts all services**

### After Setup

Once the remote host is configured, add it to RAT on your local machine:

```bash
# Using password auth (recommended for setup script defaults)
rat add myjumphost -t <share-name>

# Or with a specific key if you've added one
rat add myjumphost -t <share-name> -k ~/.ssh/mykey
```

Then connect:
```bash
rat ssh myjumphost
rat vnc myjumphost
```

### Verifying Remote Host Status

If you have another way to access the remote host, you can verify the services:

```bash
# Check all services
sudo systemctl status ssh
sudo systemctl status vncserver@1
sudo systemctl status zrok-ssh

# Check zrok share
zrok ls

# View logs if something isn't working
sudo journalctl -u zrok-ssh -f
```

## Development

### Makefile Targets

```bash
make install      # Install package
make install-dev  # Install with dev dependencies (pytest, black, pylint)
make build        # Build distribution packages
make clean        # Remove build artifacts and cache
make test         # Run tests
make coverage     # Run tests with coverage (95% minimum)
make lint         # Run pylint (expects 10.0/10)
make format       # Format code with black
make check        # Run format check and lint
make help         # Show all targets
```

### Code Quality

- **Test coverage**: 100% (95% minimum required)
- **Pylint score**: 10.0/10
- **Formatter**: black (line-length 100)

### Project Structure

```
rat/
├── rat/
│   ├── __init__.py      # Package version
│   ├── cli.py           # CLI commands and argument parsing
│   ├── config.py        # Host configuration and persistence
│   └── tunnel.py        # Zrok and SSH tunnel management
├── tests/
│   ├── __init__.py
│   ├── test_cli.py      # CLI command tests
│   ├── test_config.py   # Configuration tests
│   └── test_tunnel.py   # Tunnel management tests
├── Makefile
├── pyproject.toml
└── README.md
```

## Troubleshooting

### "sshpass: command not found"

Install sshpass:
```bash
# Ubuntu/Debian
sudo apt install sshpass

# macOS
brew install hudochenkov/sshpass/sshpass
```

### "zrok: command not found"

Install zrok:
```bash
curl -sSL https://get.openziti.io/install.bash | sudo bash -s -- zrok
```

Then enable your environment:
```bash
zrok enable <your-enable-token>
```

### VNC connection fails

1. Check if the VNC tunnel is running:
   ```bash
   rat status <name>
   ```

2. Verify the remote VNC server is running:
   ```bash
   rat ssh <name> "sudo systemctl status vncserver@1"
   ```

3. Check if the port is already in use locally:
   ```bash
   lsof -i :5901
   ```

4. Restart the VNC service on the remote host:
   ```bash
   rat ssh <name> "sudo systemctl restart vncserver@1"
   ```

### Zrok access fails

1. Verify zrok is enabled locally:
   ```bash
   zrok status
   ```

2. Check if the share token exists:
   ```bash
   zrok ls
   ```

3. Verify the remote zrok service is running:
   ```bash
   rat ssh <name> "sudo systemctl status zrok-ssh"
   ```

### Connection times out

1. Check if the remote zrok share is online:
   ```bash
   # On the remote host
   zrok ls
   sudo systemctl status zrok-ssh
   ```

2. Restart the remote zrok service:
   ```bash
   # If you have another way to access the remote host
   sudo systemctl restart zrok-ssh
   ```

### Wrong password

The default password set by the setup script is `ubuntu123` for both SSH and VNC. If you specified custom passwords during setup, update your RAT configuration to match:

```bash
rat remove <name>
rat add <name> -t <token> -p <your-password>
```

## License

MIT
