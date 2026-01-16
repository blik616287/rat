"""Tests for rat.tunnel module."""

import os
import signal
from pathlib import Path
from unittest import mock

import pytest

from rat.config import Host
from rat.tunnel import (
    PID_DIR,
    ensure_pid_dir,
    get_pid_file,
    is_process_running,
    get_tunnel_pid,
    start_daemon_process,
    start_zrok_access,
    stop_zrok_access,
    start_vnc_tunnel,
    stop_vnc_tunnel,
    stop_all_tunnels,
)


@pytest.fixture
def temp_pid_dir(tmp_path):
    """Create temporary PID directory."""
    pid_dir = tmp_path / "pids"
    with mock.patch("rat.tunnel.PID_DIR", pid_dir):
        yield pid_dir


@pytest.fixture
def sample_host():
    """Create a sample host for testing."""
    return Host(
        name="testhost",
        zrok_token="testtoken",
        ssh_user="testuser",
        ssh_key="/path/to/key",
        ports={"ssh": 2222, "vnc": 5901, "remote_vnc": 5901},
    )


@pytest.fixture
def sample_host_password():
    """Create a sample host with password auth for testing."""
    return Host(
        name="passhost",
        zrok_token="passtoken",
        ssh_user="passuser",
        ssh_key="",
        ssh_password="testpass",
        ports={"ssh": 2223, "vnc": 5902, "remote_vnc": 5902},
    )


class TestPidFunctions:
    """Tests for PID management functions."""

    def test_ensure_pid_dir(self, temp_pid_dir):
        """Test PID directory creation."""
        ensure_pid_dir()
        assert temp_pid_dir.exists()

    def test_get_pid_file(self, temp_pid_dir):
        """Test getting PID file path."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            path = get_pid_file("myhost", "zrok")
            assert path == temp_pid_dir / "myhost_zrok.pid"

    def test_is_process_running_true(self):
        """Test checking if current process is running."""
        # Current process should be running
        assert is_process_running(os.getpid()) is True

    def test_is_process_running_false(self):
        """Test checking if non-existent process is running."""
        # Use a very high PID that shouldn't exist
        assert is_process_running(999999999) is False

    def test_get_tunnel_pid_no_file(self, temp_pid_dir):
        """Test getting tunnel PID when no PID file exists."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            pid = get_tunnel_pid("nohost", "zrok")
            assert pid is None

    def test_get_tunnel_pid_with_running_process(self, temp_pid_dir):
        """Test getting tunnel PID with running process."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        pid_file = temp_pid_dir / "runninghost_zrok.pid"
        pid_file.write_text(str(os.getpid()), encoding="utf-8")
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            pid = get_tunnel_pid("runninghost", "zrok")
            assert pid == os.getpid()

    def test_get_tunnel_pid_with_dead_process(self, temp_pid_dir):
        """Test getting tunnel PID with dead process cleans up file."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        pid_file = temp_pid_dir / "deadhost_zrok.pid"
        pid_file.write_text("999999999", encoding="utf-8")
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            pid = get_tunnel_pid("deadhost", "zrok")
            assert pid is None
            assert not pid_file.exists()

    def test_get_tunnel_pid_invalid_content(self, temp_pid_dir):
        """Test getting tunnel PID with invalid PID file content."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        pid_file = temp_pid_dir / "invalid_zrok.pid"
        pid_file.write_text("notanumber", encoding="utf-8")
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            pid = get_tunnel_pid("invalid", "zrok")
            assert pid is None


class TestStartDaemonProcess:
    """Tests for start_daemon_process function."""

    def test_start_daemon_process_success(self):
        """Test starting a daemon process successfully."""
        with mock.patch("rat.tunnel.subprocess.Popen") as mock_popen:
            mock_proc = mock.MagicMock()
            mock_proc.poll.return_value = None  # Process still running
            mock_proc.pid = 12345
            mock_popen.return_value.__enter__.return_value = mock_proc
            with mock.patch("rat.tunnel.time.sleep"):
                pid = start_daemon_process(["sleep", "100"])
                assert pid == 12345

    def test_start_daemon_process_failure(self):
        """Test starting a daemon process that fails."""
        with mock.patch("rat.tunnel.subprocess.Popen") as mock_popen:
            mock_proc = mock.MagicMock()
            mock_proc.poll.return_value = 1  # Process exited
            mock_popen.return_value.__enter__.return_value = mock_proc
            with mock.patch("rat.tunnel.time.sleep"):
                pid = start_daemon_process(["false"])
                assert pid is None


class TestZrokAccess:
    """Tests for zrok access functions."""

    def test_start_zrok_access_already_running(self, temp_pid_dir, sample_host, capsys):
        """Test starting zrok when already running."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        pid_file = temp_pid_dir / "testhost_zrok.pid"
        pid_file.write_text(str(os.getpid()), encoding="utf-8")
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            result = start_zrok_access(sample_host)
            assert result is True
            captured = capsys.readouterr()
            assert "already running" in captured.out

    def test_start_zrok_access_success(self, temp_pid_dir, sample_host, capsys):
        """Test starting zrok access successfully."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.start_daemon_process", return_value=12345):
                result = start_zrok_access(sample_host)
                assert result is True
                captured = capsys.readouterr()
                assert "started" in captured.out

    def test_start_zrok_access_failure(self, temp_pid_dir, sample_host, capsys):
        """Test starting zrok access failure."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.start_daemon_process", return_value=None):
                result = start_zrok_access(sample_host)
                assert result is False
                captured = capsys.readouterr()
                assert "Failed" in captured.out

    def test_stop_zrok_access_not_running(self, temp_pid_dir, sample_host, capsys):
        """Test stopping zrok when not running."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            result = stop_zrok_access(sample_host)
            assert result is False
            captured = capsys.readouterr()
            assert "No zrok access running" in captured.out

    def test_stop_zrok_access_success(self, temp_pid_dir, sample_host, capsys):
        """Test stopping zrok access successfully."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.get_tunnel_pid", return_value=12345):
                with mock.patch("rat.tunnel.os.kill") as mock_kill:
                    with mock.patch("rat.tunnel.get_pid_file") as mock_pid_file:
                        mock_pid_file.return_value.unlink = mock.MagicMock()
                        result = stop_zrok_access(sample_host)
                        assert result is True
                        mock_kill.assert_called_once_with(12345, signal.SIGTERM)
                        captured = capsys.readouterr()
                        assert "stopped" in captured.out

    def test_stop_zrok_access_error(self, temp_pid_dir, sample_host, capsys):
        """Test stopping zrok access with error."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.get_tunnel_pid", return_value=12345):
                with mock.patch("rat.tunnel.os.kill", side_effect=OSError("test error")):
                    result = stop_zrok_access(sample_host)
                    assert result is False
                    captured = capsys.readouterr()
                    assert "Error" in captured.out


class TestVncTunnel:
    """Tests for VNC tunnel functions."""

    def test_start_vnc_tunnel_already_running(self, temp_pid_dir, sample_host, capsys):
        """Test starting VNC tunnel when already running."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        pid_file = temp_pid_dir / "testhost_vnc.pid"
        pid_file.write_text(str(os.getpid()), encoding="utf-8")
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            result = start_vnc_tunnel(sample_host)
            assert result is True
            captured = capsys.readouterr()
            assert "already running" in captured.out

    def test_start_vnc_tunnel_with_key_success(self, temp_pid_dir, sample_host, capsys):
        """Test starting VNC tunnel with key auth successfully."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.start_daemon_process", return_value=12345):
                result = start_vnc_tunnel(sample_host)
                assert result is True
                captured = capsys.readouterr()
                assert "established" in captured.out

    def test_start_vnc_tunnel_with_password_success(
        self, temp_pid_dir, sample_host_password, capsys
    ):
        """Test starting VNC tunnel with password auth successfully."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.start_daemon_process", return_value=12345):
                result = start_vnc_tunnel(sample_host_password)
                assert result is True

    def test_start_vnc_tunnel_failure(self, temp_pid_dir, sample_host, capsys):
        """Test starting VNC tunnel failure."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.start_daemon_process", return_value=None):
                result = start_vnc_tunnel(sample_host)
                assert result is False
                captured = capsys.readouterr()
                assert "Failed" in captured.out

    def test_stop_vnc_tunnel_not_running(self, temp_pid_dir, sample_host, capsys):
        """Test stopping VNC tunnel when not running."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            result = stop_vnc_tunnel(sample_host)
            assert result is False
            captured = capsys.readouterr()
            assert "No VNC tunnel running" in captured.out

    def test_stop_vnc_tunnel_success(self, temp_pid_dir, sample_host, capsys):
        """Test stopping VNC tunnel successfully."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.get_tunnel_pid", return_value=12345):
                with mock.patch("rat.tunnel.os.kill") as mock_kill:
                    with mock.patch("rat.tunnel.get_pid_file") as mock_pid_file:
                        mock_pid_file.return_value.unlink = mock.MagicMock()
                        result = stop_vnc_tunnel(sample_host)
                        assert result is True
                        mock_kill.assert_called_once_with(12345, signal.SIGTERM)

    def test_stop_vnc_tunnel_error(self, temp_pid_dir, sample_host, capsys):
        """Test stopping VNC tunnel with error."""
        temp_pid_dir.mkdir(parents=True, exist_ok=True)
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.get_tunnel_pid", return_value=12345):
                with mock.patch("rat.tunnel.os.kill", side_effect=OSError("test error")):
                    result = stop_vnc_tunnel(sample_host)
                    assert result is False


class TestStopAllTunnels:
    """Tests for stop_all_tunnels function."""

    def test_stop_all_tunnels(self, temp_pid_dir, sample_host):
        """Test stopping all tunnels."""
        with mock.patch("rat.tunnel.PID_DIR", temp_pid_dir):
            with mock.patch("rat.tunnel.stop_vnc_tunnel") as mock_vnc:
                with mock.patch("rat.tunnel.stop_zrok_access") as mock_zrok:
                    stop_all_tunnels(sample_host)
                    mock_vnc.assert_called_once_with(sample_host)
                    mock_zrok.assert_called_once_with(sample_host)
