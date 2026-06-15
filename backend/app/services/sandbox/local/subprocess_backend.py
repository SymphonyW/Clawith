"""Local subprocess-based sandbox backend."""

import asyncio
import locale
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from loguru import logger

from app.services.sandbox.base import BaseSandboxBackend, ExecutionResult, SandboxCapabilities
from app.services.sandbox.config import SandboxConfig
from app.services.workspace_paths import WorkspacePathError, resolve_path_within_root

MAX_STDOUT_CAPTURE_BYTES = 1_000_000
MAX_STDERR_CAPTURE_BYTES = 500_000


# Security patterns - reused from agent_tools.py
_DANGEROUS_BASH_ALWAYS = [
    "rm -rf /", "rm -rf ~", "sudo ", "mkfs", "dd if=",
    ":(){ :", "chmod 777 /", "chown ", "shutdown", "reboot",
]

_DANGEROUS_BASH_NETWORK = [
    "curl ", "wget ", "nc ", "ncat ", "ssh ", "scp ",
    "git clone", "git fetch", "git pull", "git ls-remote", "git submodule update",
]

_DANGEROUS_PYTHON_IMPORTS_ALWAYS = [
    "shutil.rmtree", "os.system", "os.popen",
    "os.exec", "os.spawn",
]

_DANGEROUS_PYTHON_IMPORTS_NETWORK = [
    "socket", "http.client", "urllib.request", "requests",
    "ftplib", "smtplib", "telnetlib", "ctypes",
    "git clone", "git fetch", "git pull", "git ls-remote",
]

_DANGEROUS_NODE_ALWAYS = [
    "fs.rmSync", "fs.rmdirSync", "process.exit",
]

_DANGEROUS_NODE_NETWORK = [
    "require('http')", "require('https')", "require('net')"
]


def _python_git_network_command_detected(code: str) -> bool:
    return bool(
        re.search(
            r"subprocess\.(?:run|call|popen|check_call|check_output)\s*\([^)]*"
            r"['\"]git['\"]\s*,\s*['\"](?:clone|fetch|pull|ls-remote)['\"]",
            code,
            re.DOTALL,
        )
    )


def _check_code_safety(language: str, code: str, allow_network: bool = False) -> str | None:
    """Check code for dangerous patterns. Returns error message if unsafe, None if ok."""
    code_lower = code.lower()

    if language == "bash":
        # Always check dangerous patterns
        for pattern in _DANGEROUS_BASH_ALWAYS:
            if pattern.lower() in code_lower:
                logger.warning(f"Blocked: dangerous command detected ({pattern.strip()})")
                return f"Blocked: dangerous command detected ({pattern.strip()})"
        # Network commands only when network is not allowed
        if not allow_network:
            for pattern in _DANGEROUS_BASH_NETWORK:
                if pattern.lower() in code_lower:
                    logger.warning(f"Blocked: network command not allowed ({pattern.strip()})")        
                    return f"Blocked: network command not allowed ({pattern.strip()})"
        if "../../" in code:
            return "Blocked: directory traversal not allowed"

    elif language == "python":
        # Always check dangerous patterns
        for pattern in _DANGEROUS_PYTHON_IMPORTS_ALWAYS:
            if pattern.lower() in code_lower:
                logger.warning(f"Blocked: unsafe operation detected ({pattern.strip()})")
                return f"Blocked: unsafe operation detected ({pattern.strip()})"
        # Network imports only when network is not allowed
        if not allow_network:
            for pattern in _DANGEROUS_PYTHON_IMPORTS_NETWORK:
                if pattern.lower() in code_lower:
                    logger.warning(f"Blocked: network operation not allowed ({pattern.strip()})")
                    return f"Blocked: network operation not allowed ({pattern.strip()})"
            if _python_git_network_command_detected(code_lower):
                logger.warning("Blocked: network operation not allowed (git)")
                return "Blocked: network operation not allowed (git)"

    elif language == "node":
        # Always check dangerous patterns
        for pattern in _DANGEROUS_NODE_ALWAYS:
            if pattern.lower() in code_lower:
                return f"Blocked: unsafe operation detected ({pattern})"
        # Network requires only when network is not allowed
        if not allow_network:
            for pattern in _DANGEROUS_NODE_NETWORK:
                if pattern.lower() in code_lower:
                    logger.warning(f"Blocked: network operation not allowed ({pattern.strip()})")
                    return f"Blocked: network operation not allowed ({pattern.strip()})"

    return None


class SubprocessBackend(BaseSandboxBackend):
    """Local subprocess-based sandbox backend.

    This backend executes code in a subprocess within the agent's workspace.
    It requires bubblewrap-based filesystem isolation for execute_code.
    When bubblewrap is unavailable, code execution fails closed.
    """

    name = "subprocess"
    _bwrap_missing_warned = False

    def __init__(self, config: SandboxConfig):
        self.config = config

    def _sandbox_venv_python(self) -> str:
        return "/workspace/.venv/bin/python"

    def _host_venv_bin_dir(self, work_path: Path) -> Path:
        return work_path / ".venv" / ("Scripts" if os.name == "nt" else "bin")

    def _host_venv_python(self, work_path: Path) -> str:
        exe_name = "python.exe" if os.name == "nt" else "python"
        return str(self._host_venv_bin_dir(work_path) / exe_name)

    def _host_python_command(self) -> str:
        if sys.executable:
            return sys.executable
        return shutil.which("python3") or shutil.which("python") or "python3"

    def _build_command(self, language: str, script_path: str, work_path: Path, *, use_venv: bool = True) -> list[str]:
        if language == "python":
            python_cmd = self._sandbox_venv_python() if use_venv else "python3"
            return [python_cmd, "-I", "-B", str(script_path)]
        if language == "bash":
            return ["bash", "--noprofile", "--norc", str(script_path)]
        return ["node", str(script_path)]

    def _build_host_command(
        self,
        language: str,
        script_path: Path,
        work_path: Path,
        *,
        use_venv: bool = True,
        code: str | None = None,
    ) -> list[str]:
        if language == "python":
            python_cmd = self._host_venv_python(work_path) if use_venv else self._host_python_command()
            return [python_cmd, "-I", "-B", str(script_path)]
        if language == "bash":
            if os.name == "nt" and code is not None:
                return ["bash", "--noprofile", "--norc", "-c", code]
            return ["bash", "--noprofile", "--norc", str(script_path)]
        return ["node", str(script_path)]

    def _build_safe_env(self, work_path: Path) -> dict[str, str]:
        venv_bin = self._host_venv_bin_dir(work_path)
        workspace_tmp = work_path / ".tmp"
        workspace_dir = work_path / "workspace"
        default_path = "/usr/bin:/bin" if os.name != "nt" else ""
        current_path = os.environ.get("PATH", default_path)
        env = dict(os.environ) if os.name == "nt" else {}
        env.update(
            {
                "HOME": str(work_path),
                "PATH": os.pathsep.join(part for part in (str(venv_bin), current_path) if part),
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONNOUSERSITE": "1",
                "TMPDIR": str(workspace_tmp),
                "NODE_PATH": "",
                "BASH_ENV": "",
                "ENV": "",
                "VIRTUAL_ENV": str(work_path / ".venv"),
                "PIP_CACHE_DIR": str(workspace_tmp / "pip-cache"),
                "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                "CLAWITH_AGENT_ROOT": str(work_path),
                "CLAWITH_WORKSPACE_DIR": str(workspace_dir),
                "WORKSPACE_DIR": str(workspace_dir),
            }
        )
        return env

    def _rewrite_workspace_aliases_for_host(self, code: str, work_path: Path) -> str:
        return code.replace("/workspace", work_path.as_posix())

    def _decode_output(self, data: bytes, limit: int) -> str:
        if not data:
            return ""

        encodings: list[str] = []
        if os.name == "nt" and data[:80].count(b"\x00") > 8:
            encodings.append("utf-16-le")
        encodings.append("utf-8")

        preferred = locale.getpreferredencoding(False)
        if preferred and preferred.lower() not in {encoding.lower() for encoding in encodings}:
            encodings.append(preferred)
        if os.name == "nt":
            for encoding in ("gbk", "cp936"):
                if encoding not in {item.lower() for item in encodings}:
                    encodings.append(encoding)

        best = ""
        best_replacements = 10**9
        for encoding in encodings:
            try:
                text = data.decode(encoding)
            except UnicodeDecodeError:
                text = data.decode(encoding, errors="replace")
            replacements = text.count("\ufffd")
            if replacements < best_replacements:
                best = text
                best_replacements = replacements
            if replacements == 0:
                break
        return best[:limit]

    def _bind_if_exists(self, host_path: str, guest_path: str | None = None, *, read_only: bool = True) -> list[str]:
        host = Path(host_path)
        if not host.exists():
            return []
        target = guest_path or host_path
        bind_flag = "--ro-bind" if read_only else "--bind"
        return [bind_flag, str(host), target]

    def _workspace_venv_exists(self, work_path: Path) -> bool:
        return Path(self._host_venv_python(work_path)).exists()

    def _code_should_prepare_venv(self, language: str, code: str) -> bool:
        if language == "python":
            return True
        if language != "bash":
            return False
        return bool(re.search(r"(^|[;&|]\s*)(python3?\s+-m\s+pip|pip3?)\b", code))

    def _code_requires_venv(self, language: str, code: str) -> bool:
        return language == "bash" and self._code_should_prepare_venv(language, code)

    def _ensure_workspace_venv(self, work_path: Path) -> tuple[bool, str | None]:
        venv_python = Path(self._host_venv_python(work_path))
        if not venv_python.exists():
            cmd = [self._host_python_command(), "-m", "venv", str(work_path / ".venv")]
            try:
                proc = subprocess.run(
                    cmd,
                    check=False,
                    cwd=str(work_path),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=60,
                )
            except Exception as exc:
                return False, str(exc)
            if proc.returncode != 0:
                details = (proc.stderr or proc.stdout or "").strip()
                return False, details or f"{cmd[0]} -m venv exited with {proc.returncode}"

        # Fix shebang lines in pip scripts to use bwrap-visible path
        # venv creates scripts with absolute paths to the host Python,
        # but bwrap only mounts /workspace, so those paths don't exist inside the sandbox
        self._fix_pip_shebangs(work_path)
        return True, None

    def _fix_pip_shebangs(self, work_path: Path) -> None:
        """Fix pip script shebangs to point to /workspace/.venv/bin/python for bwrap compatibility."""
        if os.name == "nt":
            return
        venv_bin = self._host_venv_bin_dir(work_path)
        sandbox_python = "/workspace/.venv/bin/python"
        for script_name in ("pip", "pip3", "pip3.X"):
            script_path = venv_bin / script_name
            if script_path.exists():
                content = script_path.read_text(encoding="utf-8")
                if content.startswith("#!"):
                    first_line, rest = content.split("\n", 1)
                    # Only rewrite if shebang doesn't already point to sandbox python
                    if sandbox_python not in first_line:
                        script_path.write_text(f"#!{sandbox_python}\n{rest}", encoding="utf-8")

    def _build_exec_kwargs(self, work_path: Path, timeout: int, use_preexec: bool = False) -> dict:
        kwargs = {
            "stdout": asyncio.subprocess.PIPE,
            "stderr": asyncio.subprocess.PIPE,
            "env": self._build_safe_env(work_path),
        }
        if use_preexec:
            kwargs["preexec_fn"] = self._build_preexec_fn(work_path, timeout)
        return kwargs

    def _build_preexec_fn(self, work_path: Path, timeout: int):
        def _preexec():
            os.chdir(work_path)
            if hasattr(os, "setsid"):
                os.setsid()
            os.umask(0o077)

            try:
                import resource

                memory_bytes = int(self.config.memory_limit.rstrip("mM")) * 1024 * 1024
                cpu_limit = max(1, min(timeout, self.config.max_timeout))
                resource.setrlimit(resource.RLIMIT_CPU, (cpu_limit, cpu_limit))
                resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))
                resource.setrlimit(resource.RLIMIT_FSIZE, (10 * 1024 * 1024, 10 * 1024 * 1024))
                resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
                resource.setrlimit(resource.RLIMIT_NPROC, (32, 32))
                if hasattr(resource, "RLIMIT_CORE"):
                    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            except Exception as exc:
                logger.warning(f"[Subprocess] Failed to apply resource limits: {exc}")

            if hasattr(os, "setgid"):
                try:
                    os.setgid(os.getgid())
                except Exception:
                    pass
            if hasattr(os, "setuid"):
                try:
                    os.setuid(os.getuid())
                except Exception:
                    pass

            if hasattr(os, "chroot") and os.geteuid() == 0:
                try:
                    os.chroot(work_path)
                    os.chdir("/")
                except Exception as exc:
                    logger.warning(f"[Subprocess] Failed to chroot into workspace: {exc}")

        return _preexec

    def _build_bwrap_command(
        self,
        command: list[str],
        work_path: Path,
        *,
        sandbox_cwd: str = "/workspace",
    ) -> list[str] | None:
        bwrap = shutil.which("bwrap")
        if not bwrap:
            if not SubprocessBackend._bwrap_missing_warned:
                logger.warning(
                    "[Subprocess] bubblewrap (bwrap) is not available. "
                    "execute_code will be rejected until bubblewrap is installed."
                )
                SubprocessBackend._bwrap_missing_warned = True
            return None

        base_binds = (
            self._bind_if_exists("/usr")
            + self._bind_if_exists("/usr/local")
            + self._bind_if_exists("/bin")
            + self._bind_if_exists("/lib")
            + self._bind_if_exists("/lib64")
            + self._bind_if_exists("/etc")
        )

        cmd = [
            bwrap,
            "--die-with-parent",
            "--new-session",
            "--unshare-user",
            "--unshare-ipc",
            "--unshare-pid",
            "--unshare-uts",
            "--unshare-cgroup",
            *base_binds,
            "--bind", str(work_path), "/workspace",
            "--dev", "/dev",
            "--proc", "/proc",
            "--dir", "/tmp",
            "--setenv", "HOME", "/workspace",
            "--setenv", "PATH", f"/workspace/.venv/bin:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "--setenv", "TMPDIR", "/workspace/.tmp",
            "--setenv", "PYTHONDONTWRITEBYTECODE", "1",
            "--setenv", "PYTHONNOUSERSITE", "1",
            "--setenv", "NODE_PATH", "",
            "--setenv", "BASH_ENV", "",
            "--setenv", "ENV", "",
            "--setenv", "VIRTUAL_ENV", "/workspace/.venv",
            "--setenv", "PIP_CACHE_DIR", "/workspace/.tmp/pip-cache",
            "--setenv", "PIP_DISABLE_PIP_VERSION_CHECK", "1",
            "--setenv", "CLAWITH_AGENT_ROOT", "/workspace",
            "--setenv", "CLAWITH_WORKSPACE_DIR", "/workspace/workspace",
            "--setenv", "WORKSPACE_DIR", "/workspace/workspace",
            "--chdir", sandbox_cwd,
        ]
        if not self.config.allow_network:
            cmd.append("--unshare-net")
        cmd.extend(command)
        return cmd

    def get_capabilities(self) -> SandboxCapabilities:
        return SandboxCapabilities(
            supported_languages=["python", "bash", "node"],
            max_timeout=self.config.max_timeout,
            max_memory_mb=256,
            network_available=self.config.allow_network,
            filesystem_available=True,
        )

    async def health_check(self) -> bool:
        """Check if basic system commands are available."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "python3", "--version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            return proc.returncode == 0
        except Exception:
            return False

    async def execute(
        self,
        code: str,
        language: str,
        timeout: int = 30,
        work_dir: str | None = None,
        **kwargs
    ) -> ExecutionResult:
        """Execute code in a subprocess."""
        on_output = kwargs.get("on_output")
        start_time = time.time()

        # Validate language
        if language not in ("python", "bash", "node"):
            return ExecutionResult(
                success=False,
                stdout="",
                stderr="",
                exit_code=1,
                duration_ms=int((time.time() - start_time) * 1000),
                error=f"Unsupported language: {language}. Use: python, bash, or node"
            )

        # Security check - pass allow_network config
        safety_error = _check_code_safety(language, code, self.config.allow_network)
        if safety_error:
            return ExecutionResult(
                success=False,
                stdout="",
                stderr="",
                exit_code=1,
                duration_ms=int((time.time() - start_time) * 1000),
                error=f"❌ {safety_error}"
            )

        # Determine work directory and ensure it cannot escape its own root.
        if work_dir:
            work_path = Path(work_dir).resolve()
        else:
            work_path = (Path.cwd() / "workspace").resolve()
        try:
            work_path = resolve_path_within_root(work_path, "", label="work_dir")
        except WorkspacePathError as exc:
            return ExecutionResult(
                success=False,
                stdout="",
                stderr="",
                exit_code=1,
                duration_ms=int((time.time() - start_time) * 1000),
                error=str(exc),
            )
        work_path.mkdir(parents=True, exist_ok=True)
        (work_path / ".tmp").mkdir(parents=True, exist_ok=True)
        (work_path / ".tmp" / "pip-cache").mkdir(parents=True, exist_ok=True)
        requested_workdir = str(kwargs.get("execution_workdir") or "").strip().replace("\\", "/")
        try:
            execution_cwd = resolve_path_within_root(work_path, requested_workdir, label="execution workdir")
        except WorkspacePathError as exc:
            return ExecutionResult(
                success=False,
                stdout="",
                stderr="",
                exit_code=1,
                duration_ms=int((time.time() - start_time) * 1000),
                error=str(exc),
            )
        execution_cwd.mkdir(parents=True, exist_ok=True)
        execution_rel = execution_cwd.relative_to(work_path).as_posix()
        sandbox_cwd = "/workspace" if execution_rel == "." else f"/workspace/{execution_rel}"

        # Determine command and file extension
        if language == "python":
            ext = ".py"
        elif language == "bash":
            ext = ".sh"
        elif language == "node":
            ext = ".js"
        
        # Write code to temp file
        script_path = work_path / f"_exec_tmp{ext}"

        try:
            should_prepare_venv = self._code_should_prepare_venv(language, code)
            venv_ready = self._workspace_venv_exists(work_path)
            venv_warning = ""
            if should_prepare_venv and not venv_ready:
                venv_ready, venv_error = self._ensure_workspace_venv(work_path)
                if not venv_ready:
                    if self._code_requires_venv(language, code):
                        duration_ms = int((time.time() - start_time) * 1000)
                        return ExecutionResult(
                            success=False,
                            stdout="",
                            stderr="",
                            exit_code=1,
                            duration_ms=duration_ms,
                            error=(
                                "Unable to create the workspace Python virtual environment needed for pip. "
                                f"{venv_error or 'No additional details were provided.'}"
                            ),
                        )
                    venv_warning = (
                        "Warning: workspace Python virtual environment could not be created; "
                        "running with the system Python instead.\n"
                    )
            sandbox_command = self._build_command(
                language,
                f"/workspace/{script_path.name}",
                work_path,
                use_venv=venv_ready,
            )
            bwrap_command = self._build_bwrap_command(sandbox_command, work_path, sandbox_cwd=sandbox_cwd)
            script_code = code if bwrap_command else self._rewrite_workspace_aliases_for_host(code, work_path)
            script_path.write_text(script_code, encoding="utf-8")
            if not bwrap_command:
                if not self.config.allow_unsafe_fallback_when_bwrap_missing:
                    duration_ms = int((time.time() - start_time) * 1000)
                    return ExecutionResult(
                        success=False,
                        stdout="",
                        stderr="",
                        exit_code=1,
                        duration_ms=duration_ms,
                        error=(
                            "bubblewrap (bwrap) is required for execute_code but is not available. "
                            "Install bwrap in the runtime environment or enable "
                            "allow_unsafe_fallback_when_bwrap_missing for local development."
                        ),
                    )

                host_command = self._build_host_command(
                    language,
                    script_path,
                    work_path,
                    use_venv=venv_ready,
                    code=script_code,
                )
                logger.warning(
                    "[Subprocess] bubblewrap missing; using local fallback without filesystem isolation"
                )
                exec_kwargs = self._build_exec_kwargs(
                    work_path,
                    timeout,
                    use_preexec=os.name != "nt",
                )
                proc = await asyncio.create_subprocess_exec(
                    *host_command,
                    cwd=str(execution_cwd),
                    **exec_kwargs,
                )
            else:
                proc = await asyncio.create_subprocess_exec(
                    *bwrap_command,
                    cwd=str(execution_cwd),
                    **self._build_exec_kwargs(work_path, timeout),
                )

            stdout_data = bytearray()
            stderr_data = bytearray()

            async def read_stream(stream, out, label="stdout"):
                capture_limit = MAX_STDERR_CAPTURE_BYTES if label == "stderr" else MAX_STDOUT_CAPTURE_BYTES
                while True:
                    chunk = await stream.read(4096)
                    if not chunk:
                        break
                    remaining = capture_limit - len(out)
                    if remaining > 0:
                        out.extend(chunk[:remaining])
                    # Real-time streaming: push each chunk to the WebSocket
                    if on_output:
                        try:
                            text = chunk.decode("utf-8", errors="replace")
                            await on_output(text, label)
                        except Exception:
                            pass

            task1 = asyncio.create_task(read_stream(proc.stdout, stdout_data, "stdout"))
            task2 = asyncio.create_task(read_stream(proc.stderr, stderr_data, "stderr"))

            is_timeout = False
            try:
                await asyncio.wait_for(proc.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                proc.kill()
                is_timeout = True

            await asyncio.gather(task1, task2)
            stdout = bytes(stdout_data)
            stderr = bytes(stderr_data)

            stdout_str = self._decode_output(stdout, 10000)
            stderr_str = self._decode_output(stderr, 5000)
            if venv_warning:
                stderr_str = f"{venv_warning}{stderr_str}"

            duration_ms = int((time.time() - start_time) * 1000)

            if is_timeout:
                return ExecutionResult(
                    success=False,
                    stdout=stdout_str,
                    stderr=stderr_str,
                    exit_code=124,
                    duration_ms=duration_ms,
                    error=f"Code execution timed out after {timeout}s. If you expect this code to take longer, try calling the tool again with a higher 'timeout' parameter (up to 3600s)."
                )

            return ExecutionResult(
                success=proc.returncode == 0,
                stdout=stdout_str,
                stderr=stderr_str,
                exit_code=proc.returncode,
                duration_ms=duration_ms,
                error=None if proc.returncode == 0 else f"Exit code: {proc.returncode}"
            )

        except Exception as e:
            duration_ms = int((time.time() - start_time) * 1000)
            logger.exception("[Subprocess] Execution error")
            return ExecutionResult(
                success=False,
                stdout="",
                stderr="",
                exit_code=1,
                duration_ms=duration_ms,
                error=f"Execution error: {str(e)[:200]}"
            )

        finally:
            # Clean up temp script
            try:
                script_path.unlink(missing_ok=True)
            except Exception:
                pass
