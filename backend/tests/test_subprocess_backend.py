import sys
from pathlib import Path

import pytest

from app.services.sandbox.config import SandboxConfig
from app.services.sandbox.local import subprocess_backend
from app.services.sandbox.local.subprocess_backend import SubprocessBackend, _check_code_safety


class _FakeStream:
    def __init__(self, chunks: list[bytes]):
        self._chunks = chunks

    async def read(self, _size: int) -> bytes:
        if not self._chunks:
            return b""
        return self._chunks.pop(0)


class _FakeProcess:
    def __init__(self, stdout: bytes = b"", stderr: bytes = b"", returncode: int = 0):
        self.stdout = _FakeStream([stdout] if stdout else [])
        self.stderr = _FakeStream([stderr] if stderr else [])
        self.returncode = returncode

    async def wait(self) -> int:
        return self.returncode

    def kill(self) -> None:
        self.returncode = -9


def _local_fallback_config(**overrides) -> SandboxConfig:
    data = {
        "allow_network": True,
        "allow_unsafe_fallback_when_bwrap_missing": True,
    }
    data.update(overrides)
    return SandboxConfig(**data)


@pytest.mark.asyncio
async def test_bash_git_clone_does_not_create_python_venv(monkeypatch, tmp_path):
    backend = SubprocessBackend(_local_fallback_config())
    recorded: dict[str, tuple] = {}

    def fail_if_called(_work_path):
        raise AssertionError("git clone through bash must not require Python venv setup")

    async def fake_create_subprocess_exec(*cmd, **kwargs):
        recorded["cmd"] = cmd
        recorded["kwargs"] = kwargs
        return _FakeProcess(stdout=b"cloned\n")

    monkeypatch.setattr(backend, "_ensure_workspace_venv", fail_if_called)
    monkeypatch.setattr(backend, "_build_bwrap_command", lambda _command, _work_path, **_kwargs: None)
    monkeypatch.setattr(subprocess_backend.asyncio, "create_subprocess_exec", fake_create_subprocess_exec)

    result = await backend.execute(
        code="git clone https://github.com/example/repo.git workspace/repo",
        language="bash",
        work_dir=str(tmp_path),
        execution_workdir="workspace",
    )

    assert result.success is True
    assert result.stdout == "cloned\n"
    assert recorded["cmd"][0] == "bash"
    assert recorded["kwargs"]["cwd"] == str(tmp_path / "workspace")


@pytest.mark.asyncio
async def test_python_execution_falls_back_when_workspace_venv_cannot_be_created(monkeypatch, tmp_path):
    backend = SubprocessBackend(_local_fallback_config())
    recorded: dict[str, tuple] = {}

    async def fake_create_subprocess_exec(*cmd, **kwargs):
        recorded["cmd"] = cmd
        recorded["kwargs"] = kwargs
        return _FakeProcess(stdout=b"ok\n")

    monkeypatch.setattr(backend, "_ensure_workspace_venv", lambda _work_path: (False, "ensurepip unavailable"))
    monkeypatch.setattr(backend, "_build_bwrap_command", lambda _command, _work_path, **_kwargs: None)
    monkeypatch.setattr(subprocess_backend.asyncio, "create_subprocess_exec", fake_create_subprocess_exec)

    result = await backend.execute(
        code="print('ok')",
        language="python",
        work_dir=str(tmp_path),
    )

    assert result.success is True
    assert result.stdout == "ok\n"
    assert "system Python" in result.stderr
    assert recorded["cmd"][0] == (sys.executable or "python3")


@pytest.mark.asyncio
async def test_host_fallback_rewrites_workspace_alias(monkeypatch, tmp_path):
    backend = SubprocessBackend(_local_fallback_config())
    recorded: dict[str, str] = {}

    async def fake_create_subprocess_exec(*cmd, **kwargs):
        script_path = Path(cmd[-1])
        recorded["script"] = script_path.read_text(encoding="utf-8")
        return _FakeProcess(stdout=b"ok\n")

    monkeypatch.setattr(backend, "_ensure_workspace_venv", lambda _work_path: (False, "ensurepip unavailable"))
    monkeypatch.setattr(backend, "_build_bwrap_command", lambda _command, _work_path, **_kwargs: None)
    monkeypatch.setattr(subprocess_backend.asyncio, "create_subprocess_exec", fake_create_subprocess_exec)

    result = await backend.execute(
        code="import os\nos.chdir('/workspace')\nprint(os.getcwd())",
        language="python",
        work_dir=str(tmp_path),
    )

    assert result.success is True
    assert "/workspace" not in recorded["script"]
    assert tmp_path.as_posix() in recorded["script"]


def test_git_network_commands_require_network_access():
    assert _check_code_safety("bash", "git clone https://github.com/example/repo.git", False)
    assert _check_code_safety("bash", "git clone https://github.com/example/repo.git", True) is None
    assert _check_code_safety("python", "subprocess.run('git clone https://example.com/repo.git')", False)
    assert _check_code_safety(
        "python",
        "subprocess.run(['git', 'clone', 'https://example.com/repo.git'])",
        False,
    )
