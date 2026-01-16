"""Tests for rat.cli module."""

import sys
from unittest import mock

import pytest

from rat.cli import (
    cmd_ssh,
    cmd_vnc,
    cmd_add,
    cmd_remove,
    cmd_list,
    cmd_status,
    cmd_stop,
    setup_parsers,
    main,
)
from rat.config import Host, DEFAULT_PASSWORD


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
    """Create a sample host with password auth."""
    return Host(
        name="passhost",
        zrok_token="passtoken",
        ssh_user="passuser",
        ssh_key="",
        ssh_password="testpass",
        ports={"ssh": 2223, "vnc": 5902, "remote_vnc": 5902},
    )


class MockArgs:
    """Mock argparse args object."""

    def __init__(self, **kwargs):
        for key, value in kwargs.items():
            setattr(self, key, value)


class TestCmdSsh:
    """Tests for cmd_ssh function."""

    def test_cmd_ssh_host_not_found(self, capsys):
        """Test SSH command with non-existent host."""
        args = MockArgs(name="nonexistent", command=[])
        with mock.patch("rat.cli.get_host", return_value=None):
            with pytest.raises(SystemExit) as exc_info:
                cmd_ssh(args)
            assert exc_info.value.code == 1
        captured = capsys.readouterr()
        assert "not found" in captured.out

    def test_cmd_ssh_zrok_fails(self, sample_host):
        """Test SSH command when zrok access fails."""
        args = MockArgs(name="testhost", command=[])
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.start_zrok_access", return_value=False):
                with pytest.raises(SystemExit) as exc_info:
                    cmd_ssh(args)
                assert exc_info.value.code == 1

    def test_cmd_ssh_with_key(self, sample_host):
        """Test SSH command with key authentication."""
        args = MockArgs(name="testhost", command=[])
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.start_zrok_access", return_value=True):
                with mock.patch("os.execvp") as mock_exec:
                    cmd_ssh(args)
                    mock_exec.assert_called_once()
                    call_args = mock_exec.call_args
                    assert call_args[0][0] == "ssh"
                    assert "-i" in call_args[0][1]

    def test_cmd_ssh_with_password(self, sample_host_password):
        """Test SSH command with password authentication."""
        args = MockArgs(name="passhost", command=[])
        with mock.patch("rat.cli.get_host", return_value=sample_host_password):
            with mock.patch("rat.cli.start_zrok_access", return_value=True):
                with mock.patch("os.execvp") as mock_exec:
                    cmd_ssh(args)
                    mock_exec.assert_called_once()
                    call_args = mock_exec.call_args
                    assert call_args[0][0] == "sshpass"

    def test_cmd_ssh_with_command(self, sample_host):
        """Test SSH command with remote command."""
        args = MockArgs(name="testhost", command=["ls", "-la"])
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.start_zrok_access", return_value=True):
                with mock.patch("os.execvp") as mock_exec:
                    cmd_ssh(args)
                    call_args = mock_exec.call_args
                    assert "ls" in call_args[0][1]
                    assert "-la" in call_args[0][1]


class TestCmdVnc:
    """Tests for cmd_vnc function."""

    def test_cmd_vnc_host_not_found(self, capsys):
        """Test VNC command with non-existent host."""
        args = MockArgs(name="nonexistent")
        with mock.patch("rat.cli.get_host", return_value=None):
            with pytest.raises(SystemExit) as exc_info:
                cmd_vnc(args)
            assert exc_info.value.code == 1

    def test_cmd_vnc_zrok_fails(self, sample_host):
        """Test VNC command when zrok access fails."""
        args = MockArgs(name="testhost")
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.start_zrok_access", return_value=False):
                with pytest.raises(SystemExit) as exc_info:
                    cmd_vnc(args)
                assert exc_info.value.code == 1

    def test_cmd_vnc_tunnel_fails(self, sample_host):
        """Test VNC command when VNC tunnel fails."""
        args = MockArgs(name="testhost")
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.start_zrok_access", return_value=True):
                with mock.patch("rat.cli.start_vnc_tunnel", return_value=False):
                    with pytest.raises(SystemExit) as exc_info:
                        cmd_vnc(args)
                    assert exc_info.value.code == 1

    def test_cmd_vnc_success(self, sample_host, capsys):
        """Test VNC command success."""
        args = MockArgs(name="testhost")
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.start_zrok_access", return_value=True):
                with mock.patch("rat.cli.start_vnc_tunnel", return_value=True):
                    with mock.patch("rat.cli.subprocess.Popen") as mock_popen:
                        mock_popen.return_value.__enter__ = mock.MagicMock()
                        mock_popen.return_value.__exit__ = mock.MagicMock()
                        cmd_vnc(args)
                        mock_popen.assert_called_once()
                        captured = capsys.readouterr()
                        assert "Launching VNC viewer" in captured.out


class TestCmdAdd:
    """Tests for cmd_add function."""

    def test_cmd_add_with_key(self, capsys):
        """Test adding a host with key authentication."""
        args = MockArgs(
            name="newhost",
            token="newtoken",
            user="newuser",
            key="~/.ssh/id_rsa",
            password=DEFAULT_PASSWORD,
            ssh_port=2222,
            vnc_port=5901,
            remote_vnc_port=5901,
        )
        with mock.patch("rat.cli.add_host") as mock_add:
            cmd_add(args)
            mock_add.assert_called_once()
            captured = capsys.readouterr()
            assert "added" in captured.out
            assert "key" in captured.out

    def test_cmd_add_with_password(self, capsys):
        """Test adding a host with password authentication."""
        args = MockArgs(
            name="passhost",
            token="passtoken",
            user="passuser",
            key=None,
            password="mypassword",
            ssh_port=2222,
            vnc_port=5901,
            remote_vnc_port=5901,
        )
        with mock.patch("rat.cli.add_host") as mock_add:
            cmd_add(args)
            mock_add.assert_called_once()
            captured = capsys.readouterr()
            assert "password" in captured.out


class TestCmdRemove:
    """Tests for cmd_remove function."""

    def test_cmd_remove_success(self, capsys):
        """Test removing a host successfully."""
        args = MockArgs(name="toremove")
        with mock.patch("rat.cli.remove_host", return_value=True):
            cmd_remove(args)
            captured = capsys.readouterr()
            assert "removed" in captured.out

    def test_cmd_remove_not_found(self, capsys):
        """Test removing a non-existent host."""
        args = MockArgs(name="nonexistent")
        with mock.patch("rat.cli.remove_host", return_value=False):
            with pytest.raises(SystemExit) as exc_info:
                cmd_remove(args)
            assert exc_info.value.code == 1
            captured = capsys.readouterr()
            assert "not found" in captured.out


class TestCmdList:
    """Tests for cmd_list function."""

    def test_cmd_list_empty(self, capsys):
        """Test listing hosts when none configured."""
        args = MockArgs()
        with mock.patch("rat.cli.list_hosts", return_value={}):
            cmd_list(args)
            captured = capsys.readouterr()
            assert "No hosts configured" in captured.out

    def test_cmd_list_with_hosts(self, sample_host, capsys):
        """Test listing configured hosts."""
        args = MockArgs()
        with mock.patch("rat.cli.list_hosts", return_value={"testhost": sample_host}):
            with mock.patch("rat.cli.get_tunnel_pid", return_value=None):
                cmd_list(args)
                captured = capsys.readouterr()
                assert "testhost" in captured.out
                assert "testtoken" in captured.out

    def test_cmd_list_with_running_tunnels(self, sample_host, capsys):
        """Test listing hosts with running tunnels."""
        args = MockArgs()
        with mock.patch("rat.cli.list_hosts", return_value={"testhost": sample_host}):
            with mock.patch("rat.cli.get_tunnel_pid", side_effect=[12345, 12346]):
                cmd_list(args)
                captured = capsys.readouterr()
                assert "zrok:12345" in captured.out
                assert "vnc:12346" in captured.out


class TestCmdStatus:
    """Tests for cmd_status function."""

    def test_cmd_status_not_found(self, capsys):
        """Test status of non-existent host."""
        args = MockArgs(name="nonexistent")
        with mock.patch("rat.cli.get_host", return_value=None):
            with pytest.raises(SystemExit) as exc_info:
                cmd_status(args)
            assert exc_info.value.code == 1

    def test_cmd_status_with_key(self, sample_host, capsys):
        """Test status of host with key auth."""
        args = MockArgs(name="testhost")
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.get_tunnel_pid", return_value=None):
                cmd_status(args)
                captured = capsys.readouterr()
                assert "testhost" in captured.out
                assert "key" in captured.out
                assert "stopped" in captured.out

    def test_cmd_status_with_password(self, sample_host_password, capsys):
        """Test status of host with password auth."""
        args = MockArgs(name="passhost")
        with mock.patch("rat.cli.get_host", return_value=sample_host_password):
            with mock.patch("rat.cli.get_tunnel_pid", return_value=None):
                cmd_status(args)
                captured = capsys.readouterr()
                assert "password" in captured.out

    def test_cmd_status_running(self, sample_host, capsys):
        """Test status of host with running tunnels."""
        args = MockArgs(name="testhost")
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.get_tunnel_pid", side_effect=[12345, 12346]):
                cmd_status(args)
                captured = capsys.readouterr()
                assert "running" in captured.out
                assert "12345" in captured.out


class TestCmdStop:
    """Tests for cmd_stop function."""

    def test_cmd_stop_not_found(self, capsys):
        """Test stopping tunnels for non-existent host."""
        args = MockArgs(name="nonexistent")
        with mock.patch("rat.cli.get_host", return_value=None):
            with pytest.raises(SystemExit) as exc_info:
                cmd_stop(args)
            assert exc_info.value.code == 1

    def test_cmd_stop_success(self, sample_host):
        """Test stopping tunnels successfully."""
        args = MockArgs(name="testhost")
        with mock.patch("rat.cli.get_host", return_value=sample_host):
            with mock.patch("rat.cli.stop_all_tunnels") as mock_stop:
                cmd_stop(args)
                mock_stop.assert_called_once_with(sample_host)


class TestSetupParsers:
    """Tests for setup_parsers function."""

    def test_setup_parsers(self):
        """Test that all parsers are set up correctly."""
        import argparse

        parser = argparse.ArgumentParser()
        subparsers = parser.add_subparsers(dest="command")
        setup_parsers(subparsers)

        # Test ssh parser
        args = parser.parse_args(["ssh", "myhost"])
        assert args.name == "myhost"
        assert args.func == cmd_ssh

        # Test vnc parser
        args = parser.parse_args(["vnc", "myhost"])
        assert args.name == "myhost"
        assert args.func == cmd_vnc

        # Test add parser
        args = parser.parse_args(["add", "myhost", "-t", "token"])
        assert args.name == "myhost"
        assert args.token == "token"
        assert args.user == "ubuntu"
        assert args.func == cmd_add

        # Test remove parser
        args = parser.parse_args(["remove", "myhost"])
        assert args.func == cmd_remove

        # Test list parser
        args = parser.parse_args(["list"])
        assert args.func == cmd_list

        # Test status parser
        args = parser.parse_args(["status", "myhost"])
        assert args.func == cmd_status

        # Test stop parser
        args = parser.parse_args(["stop", "myhost"])
        assert args.func == cmd_stop


class TestMain:
    """Tests for main function."""

    def test_main_no_command(self, capsys):
        """Test main with no command shows help."""
        with mock.patch.object(sys, "argv", ["rat"]):
            with pytest.raises(SystemExit) as exc_info:
                main()
            assert exc_info.value.code == 1

    def test_main_with_version(self, capsys):
        """Test main with version flag."""
        with mock.patch.object(sys, "argv", ["rat", "--version"]):
            with pytest.raises(SystemExit) as exc_info:
                main()
            assert exc_info.value.code == 0
            captured = capsys.readouterr()
            assert "0.1.0" in captured.out

    def test_main_with_command(self):
        """Test main with a command."""
        with mock.patch.object(sys, "argv", ["rat", "list"]):
            with mock.patch("rat.cli.list_hosts", return_value={}):
                main()
