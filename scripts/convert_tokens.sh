#!/usr/bin/env python3
"""将 ~/.cli-proxy-api/token*.json 转换为 codex-auth 可读的 auth.json 格式"""

import json
import glob
import os
import sys


def convert(src_dir: str, out_dir: str) -> int:
    src_dir = os.path.expanduser(src_dir)
    out_dir = os.path.expanduser(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    files = sorted(glob.glob(os.path.join(src_dir, "token*.json")))
    if not files:
        print(f"未找到 {src_dir}/token*.json")
        return 0

    count = 0
    for f in files:
        with open(f) as fh:
            data = json.load(fh)

        rt = data.get("refresh_token")
        if not rt:
            print(f"[SKIP] {os.path.basename(f)}: 无 refresh_token")
            continue

        auth = {
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": None,
            "tokens": {
                "id_token": data.get("id_token", ""),
                "access_token": data.get("access_token", ""),
                "refresh_token": rt,
                "account_id": data.get("account_id", ""),
            },
            "last_refresh": data.get("last_refresh", ""),
        }

        email = data.get("email", "unknown")
        out_path = os.path.join(out_dir, f"{email}.auth.json")
        with open(out_path, "w") as fh:
            json.dump(auth, fh, indent=2)
            fh.write("\n")

        print(f"  {email}")
        count += 1

    return count


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "~/.cli-proxy-api"
    dst = sys.argv[2] if len(sys.argv) > 2 else "/tmp/tokens"

    print(f"源目录: {src}")
    print(f"输出目录: {dst}")
    print()
    n = convert(src, dst)
    print(f"\n转换完成: {n} 个文件")
