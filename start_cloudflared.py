#!/usr/bin/env python3

import os
import sys
import json
import time
import ctypes
import urllib.request
from ctypes import c_int, c_char_p


def get_arch():
    """获取 CPU 架构：amd64 或 arm64"""
    machine = os.uname().machine.lower()
    if machine in ('arm64', 'aarch64'):
        return 'arm64'
    return 'amd64'


def download_file(url: str, dest: str):
    """使用标准库下载文件，失败抛出异常"""
    print(f"Downloading {url} ...")
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=180) as resp:
        with open(dest, 'wb') as f:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                f.write(chunk)
    os.chmod(dest, 0o755)


def main():
    # 从环境变量读取自定义下载地址，若未设置则使用你自己的 Release 永久链接
    BASE_URL = os.environ.get(
        'CLOUDFLARED_LIB_URL',
        'https://github.com/oyz8/nz/releases/latest/download'
    )
    # 文件名必须与 Release 中的资产名一致：bot-amd64.so 或 bot-arm64.so
    LIB_NAME = f'bot-{get_arch()}.so'
    LIB_PATH = os.path.join('/tmp', LIB_NAME)

    # 若库不存在则下载
    if not os.path.exists(LIB_PATH):
        try:
            download_file(f"{BASE_URL}/{LIB_NAME}", LIB_PATH)
        except Exception as e:
            print(f"Failed to download cloudflared library: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"Using existing library: {LIB_PATH}")

    # 从环境变量获取 ARGO_AUTH
    argo_auth = os.environ.get('ARGO_AUTH', '')
    if not argo_auth:
        print("ERROR: ARGO_AUTH environment variable not set.", file=sys.stderr)
        sys.exit(1)

    # 构建传递给动态库的启动参数（JSON 字符串）
    args_payload = {
        "args": [
            "tunnel",
            "--edge-ip-version", "auto",
            "--no-autoupdate",
            "--protocol", "http2",
            "run",
            "--token", argo_auth
        ]
    }
    payload_str = json.dumps(args_payload)

    # 加载动态库并调用 StartCloudflared 函数
    try:
        lib = ctypes.CDLL(LIB_PATH)
        start_func = lib.StartCloudflared
        start_func.argtypes = [c_char_p]
        start_func.restype = c_int

        print("Starting cloudflared tunnel via dynamic library...")
        exit_code = start_func(payload_str.encode('utf-8'))
        print(f"cloudflared started (code {exit_code}), keeping alive...")

        # 保持进程不退出，确保容器健康检查能检测到
        while True:
            time.sleep(60)
            # 可选心跳日志（需要时可取消注释）
            # print("cloudflared heartbeat: alive")

    except Exception as e:
        print(f"Failed to start cloudflared: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
