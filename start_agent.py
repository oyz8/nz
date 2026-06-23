#!/usr/bin/env python3
"""
nezha-agent 动态库启动器
"""

import os
import sys
import json
import ctypes
import signal
import time
import hashlib
import threading
import requests
from ctypes import c_int, c_char_p

# ======================== 路径与架构 ========================
FILE_PATH = os.environ.get('FILE_PATH', '.cache')
ROOT = os.getcwd()
runtimeFilePath = os.path.join(ROOT, FILE_PATH)

def get_arch():
    machine = os.uname().machine.lower()
    if machine in ('arm64', 'aarch64'):
        return 'arm64'
    return 'amd64'

ARCH = get_arch()

# ======================== 下载库文件 ========================
def sha256_file(filepath):
    sha256_hash = hashlib.sha256()
    with open(filepath, 'rb') as f:
        for byte_block in iter(lambda: f.read(4096), b''):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()

def download_library(url: str, filename: str, expected_sha256: str = None) -> str:
    target = os.path.join(runtimeFilePath, filename)
    if os.path.exists(target):
        if expected_sha256 is None or sha256_file(target) == expected_sha256:
            print(f"[agent] Using cached native library: {target}", flush=True)
            return target

    os.makedirs(runtimeFilePath, exist_ok=True)
    tmp = os.path.join(runtimeFilePath, f'{filename}.download')
    print(f"[agent] Downloading {url} -> {target}", flush=True)

    response = requests.get(url, stream=True, timeout=180)
    response.raise_for_status()
    with open(tmp, 'wb') as f:
        for chunk in response.iter_content(chunk_size=8192):
            f.write(chunk)

    if expected_sha256 and sha256_file(tmp) != expected_sha256:
        raise Exception(f"SHA-256 mismatch for {tmp}")

    os.rename(tmp, target)
    os.chmod(target, 0o755)
    return target

# ======================== 服务封装 ========================
class AgentService:
    def __init__(self, lib_path: str, config_path: str):
        self.lib_path = lib_path
        self.config_path = config_path
        self.lib = None
        self._stop_func = None
        self._running = False
        self._thread = None

    def _build_payload(self) -> str:
        return json.dumps({'config': self.config_path})

    def start(self):
        print(f"[agent] Loading library: {self.lib_path}", flush=True)
        self.lib = ctypes.CDLL(self.lib_path)

        start_func = self.lib.StartNezhaAgent
        start_func.argtypes = [c_char_p]
        start_func.restype = c_int

        self._stop_func = self.lib.StopNezhaAgent
        self._stop_func.argtypes = []
        self._stop_func.restype = c_int

        payload = self._build_payload()
        print(f"[agent] Starting with payload: {payload}", flush=True)

        def run():
            try:
                result = start_func(payload.encode('utf-8'))
                print(f"[agent] StartNezhaAgent exited with code {result}", flush=True)
            except Exception as e:
                print(f"[agent] StartNezhaAgent exception: {e}", flush=True)

        self._thread = threading.Thread(target=run, daemon=True, name='nezha-agent-thread')
        self._thread.start()
        self._running = True
        print(f"[agent] nezha-agent started", flush=True)

    def stop(self):
        if not self._running or self._stop_func is None:
            return
        try:
            result = self._stop_func()
            self._running = False
            print(f"[agent] StopNezhaAgent returned: {result}", flush=True)
        except Exception as e:
            print(f"[agent] StopNezhaAgent exception: {e}", flush=True)

    def is_alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

# ======================== 主流程 ========================
_service: AgentService = None

def signal_handler(signum, frame):
    print(f"[agent] Received signal {signum}, stopping...", flush=True)
    if _service:
        _service.stop()
    sys.exit(0)

def main():
    global _service

    if len(sys.argv) < 2:
        print("[agent] Usage: python3 /start_agent.py <config_path>", flush=True)
        sys.exit(1)

    config_path = sys.argv[1]
    if not os.path.exists(config_path):
        print(f"[agent] Config file not found: {config_path}", flush=True)
        sys.exit(1)

    print(f"[agent] Arch: {ARCH}", flush=True)
    print(f"[agent] Config: {config_path}", flush=True)
    print(f"[agent] Library dir: {runtimeFilePath}", flush=True)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # 下载地址
    AGENT_LIB_URL = os.environ.get(
        'AGENT_LIB_URL',
        'https://github.com/oyz8/nz/releases/latest/download'
    )
    so_filename = f'v1-{ARCH}.so'
    so_url = f'{AGENT_LIB_URL}/{so_filename}'

    try:
        lib_path = download_library(so_url, so_filename)
    except Exception as e:
        print(f"[agent] Failed to download library: {e}", flush=True)
        sys.exit(1)

    _service = AgentService(lib_path, config_path)
    try:
        _service.start()
    except Exception as e:
        print(f"[agent] Failed to start: {e}", flush=True)
        sys.exit(1)

    while True:
        time.sleep(5)
        if not _service.is_alive():
            print("[agent] Service thread died, exiting...", flush=True)
            sys.exit(1)

if __name__ == '__main__':
    main()
