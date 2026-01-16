"""Tests for rat.config module."""

import json
import tempfile
from pathlib import Path
from unittest import mock

import pytest

from rat.config import (
    Host,
    DEFAULT_PASSWORD,
    ensure_config_dir,
    load_hosts,
    save_hosts,
    get_host,
    add_host,
    remove_host,
    list_hosts,
    CONFIG_DIR,
    CONFIG_FILE,
)


class TestHost:
    """Tests for Host dataclass."""

    def test_host_creation_defaults(self):
        """Test creating a host with default values."""
        host = Host(name="test", zrok_token="token123", ssh_user="ubuntu")
        assert host.name == "test"
        assert host.zrok_token == "token123"
        assert host.ssh_user == "ubuntu"
        assert host.ssh_key == ""
        assert host.ssh_password == DEFAULT_PASSWORD
        assert host.ssh_port == 2222
        assert host.vnc_port == 5901
        assert host.remote_vnc_port == 5901

    def test_host_creation_custom_values(self):
        """Test creating a host with custom values."""
        host = Host(
            name="custom",
            zrok_token="mytoken",
            ssh_user="admin",
            ssh_key="/path/to/key",
            ssh_password="secret",
            ports={"ssh": 3333, "vnc": 5902, "remote_vnc": 5903},
        )
        assert host.name == "custom"
        assert host.ssh_key == "/path/to/key"
        assert host.ssh_password == "secret"
        assert host.ssh_port == 3333
        assert host.vnc_port == 5902
        assert host.remote_vnc_port == 5903

    def test_host_to_dict(self):
        """Test converting host to dictionary."""
        host = Host(name="test", zrok_token="token", ssh_user="user")
        data = host.to_dict()
        assert data["name"] == "test"
        assert data["zrok_token"] == "token"
        assert data["ssh_user"] == "user"
        assert "ports" in data

    def test_host_from_dict(self):
        """Test creating host from dictionary."""
        data = {
            "name": "fromdict",
            "zrok_token": "token",
            "ssh_user": "testuser",
            "ssh_key": "/key",
            "ssh_password": "pass",
            "ports": {"ssh": 2222, "vnc": 5901, "remote_vnc": 5901},
        }
        host = Host.from_dict(data)
        assert host.name == "fromdict"
        assert host.ssh_key == "/key"

    def test_host_from_dict_legacy_format(self):
        """Test creating host from legacy dictionary format."""
        data = {
            "name": "legacy",
            "zrok_token": "token",
            "ssh_user": "user",
            "ssh_port": 2223,
            "vnc_port": 5902,
            "remote_vnc_port": 5903,
        }
        host = Host.from_dict(data)
        assert host.name == "legacy"
        assert host.ssh_port == 2223
        assert host.vnc_port == 5902
        assert host.remote_vnc_port == 5903

    def test_port_properties_with_missing_keys(self):
        """Test port properties return defaults when keys missing."""
        host = Host(name="test", zrok_token="token", ssh_user="user", ports={})
        assert host.ssh_port == 2222
        assert host.vnc_port == 5901
        assert host.remote_vnc_port == 5901


class TestConfigFunctions:
    """Tests for config file functions."""

    @pytest.fixture
    def temp_config_dir(self, tmp_path):
        """Create temporary config directory."""
        config_dir = tmp_path / ".config" / "rat"
        config_file = config_dir / "hosts.json"
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                yield config_dir, config_file

    def test_ensure_config_dir(self, temp_config_dir):
        """Test config directory creation."""
        config_dir, _ = temp_config_dir
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            ensure_config_dir()
            assert config_dir.exists()

    def test_load_hosts_empty(self, temp_config_dir):
        """Test loading hosts when no config file exists."""
        config_dir, config_file = temp_config_dir
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                hosts = load_hosts()
                assert hosts == {}

    def test_load_hosts_with_data(self, temp_config_dir):
        """Test loading hosts from config file."""
        config_dir, config_file = temp_config_dir
        config_dir.mkdir(parents=True, exist_ok=True)
        data = {
            "host1": {
                "name": "host1",
                "zrok_token": "token1",
                "ssh_user": "user1",
                "ssh_key": "",
                "ssh_password": "pass",
                "ports": {"ssh": 2222, "vnc": 5901, "remote_vnc": 5901},
            }
        }
        config_file.write_text(json.dumps(data), encoding="utf-8")
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                hosts = load_hosts()
                assert "host1" in hosts
                assert hosts["host1"].zrok_token == "token1"

    def test_save_hosts(self, temp_config_dir):
        """Test saving hosts to config file."""
        config_dir, config_file = temp_config_dir
        host = Host(name="savetest", zrok_token="token", ssh_user="user")
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                save_hosts({"savetest": host})
                assert config_file.exists()
                data = json.loads(config_file.read_text(encoding="utf-8"))
                assert "savetest" in data

    def test_get_host_exists(self, temp_config_dir):
        """Test getting an existing host."""
        config_dir, config_file = temp_config_dir
        config_dir.mkdir(parents=True, exist_ok=True)
        data = {
            "myhost": {
                "name": "myhost",
                "zrok_token": "tok",
                "ssh_user": "usr",
                "ssh_key": "",
                "ssh_password": "p",
                "ports": {"ssh": 2222, "vnc": 5901, "remote_vnc": 5901},
            }
        }
        config_file.write_text(json.dumps(data), encoding="utf-8")
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                host = get_host("myhost")
                assert host is not None
                assert host.name == "myhost"

    def test_get_host_not_exists(self, temp_config_dir):
        """Test getting a non-existent host."""
        config_dir, config_file = temp_config_dir
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                host = get_host("nonexistent")
                assert host is None

    def test_add_host(self, temp_config_dir):
        """Test adding a host."""
        config_dir, config_file = temp_config_dir
        host = Host(name="newhost", zrok_token="token", ssh_user="user")
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                add_host(host)
                loaded = get_host("newhost")
                assert loaded is not None
                assert loaded.zrok_token == "token"

    def test_remove_host_exists(self, temp_config_dir):
        """Test removing an existing host."""
        config_dir, config_file = temp_config_dir
        host = Host(name="toremove", zrok_token="token", ssh_user="user")
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                add_host(host)
                result = remove_host("toremove")
                assert result is True
                assert get_host("toremove") is None

    def test_remove_host_not_exists(self, temp_config_dir):
        """Test removing a non-existent host."""
        config_dir, config_file = temp_config_dir
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                result = remove_host("doesnotexist")
                assert result is False

    def test_list_hosts(self, temp_config_dir):
        """Test listing all hosts."""
        config_dir, config_file = temp_config_dir
        host1 = Host(name="host1", zrok_token="t1", ssh_user="u1")
        host2 = Host(name="host2", zrok_token="t2", ssh_user="u2")
        with mock.patch("rat.config.CONFIG_DIR", config_dir):
            with mock.patch("rat.config.CONFIG_FILE", config_file):
                add_host(host1)
                add_host(host2)
                hosts = list_hosts()
                assert len(hosts) == 2
                assert "host1" in hosts
                assert "host2" in hosts
