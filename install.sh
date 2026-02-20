#!/usr/bin/env bash
set -euo pipefail
set +H

VERSION="1.3.0"

APP_DIR="/opt/v2subagg"
ETC_DIR="/etc/v2subagg"
WWW_DIR="/var/www/sub"

OUT_NAME="1111.text"
OUT_FILE="${WWW_DIR}/${OUT_NAME}"

SVC="/etc/systemd/system/v2subagg.service"
TMR="/etc/systemd/system/v2subagg.timer"

NG_AV="/etc/nginx/sites-available/sub"
NG_EN="/etc/nginx/sites-enabled/sub"

BIN="/usr/local/bin/v2subagg"

DEFAULT_PORT="8443"
DEFAULT_PATH="/${OUT_NAME}"
DEFAULT_INTERVAL="10"
DEFAULT_SCHEME="http"

detect_pm() {
  if command -v apt >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
  echo ""
}

install_pkgs() {
  local pm; pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    echo "Unsupported package manager. Please install python3 and nginx manually."
    exit 2
  fi

  if [[ "$pm" == "apt" ]]; then
    apt update
    apt install -y "$@"
  elif [[ "$pm" == "dnf" ]]; then
    dnf install -y "$@"
  elif [[ "$pm" == "yum" ]]; then
    yum install -y "$@"
  elif [[ "$pm" == "pacman" ]]; then
    pacman -Sy --noconfirm "$@"
  fi
}

ensure_deps() {
  command -v python3 >/dev/null 2>&1 || install_pkgs python3
  command -v nginx   >/dev/null 2>&1 || install_pkgs nginx
}

write_config_if_missing() {
  mkdir -p "$ETC_DIR"
  if [[ ! -f "$ETC_DIR/config.json" ]]; then
    cat >"$ETC_DIR/config.json" <<EOF
{
  "sources": [],
  "interval_minutes": ${DEFAULT_INTERVAL},
  "scheme": "${DEFAULT_SCHEME}",
  "port": ${DEFAULT_PORT},
  "path": "${DEFAULT_PATH}",
  "host": ""
}
EOF
  fi
}

write_aggregator() {
  mkdir -p "$APP_DIR" "$WWW_DIR"
  cat >"$APP_DIR/agg.py" <<'PY'
#!/usr/bin/env python3
import base64, hashlib, json, os, re, sys
from pathlib import Path
from urllib.request import Request, urlopen

CONFIG = Path("/etc/v2subagg/config.json")
OUT_PATH = Path("/var/www/sub/1111.text")

UA = "Mozilla/5.0 (sub-aggregator)"
PREFIXES = ("vmess://","vless://","trojan://","ss://","hysteria://","hy2://","tuic://")

def fetch(url: str) -> bytes:
    req = Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
    with urlopen(req, timeout=30) as r:
        return r.read()

def b64decode_relaxed(data: bytes) -> str:
    # Try to base64-decode; if not valid, return raw text.
    s = data.strip().replace(b"\n", b"").replace(b"\r", b"")
    s += b"=" * ((-len(s)) % 4)
    try:
        txt = base64.b64decode(s).decode("utf-8", "ignore")
        # If decoded looks like subscriptions, use it.
        if "://" in txt:
            return txt
    except Exception:
        pass
    return data.decode("utf-8", "ignore")

def b64encode_clean(text: str) -> str:
    return base64.b64encode(text.strip().encode("utf-8")).decode("ascii")

def load_sources():
    if not CONFIG.exists():
        return []
    try:
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        return [x.strip() for x in cfg.get("sources", []) if isinstance(x, str) and x.strip()]
    except Exception:
        return []

def main():
    sources = load_sources()
    if not sources:
        print("No sources in config.", file=sys.stderr)
        sys.exit(1)

    lines = []
    failures = 0

    for url in sources:
        try:
            content = fetch(url)
            decoded = b64decode_relaxed(content)

            # Split by ANY whitespace (spaces/newlines/tabs)
            for token in re.split(r"\s+", decoded.strip()):
                token = token.strip()
                if token and token.startswith(PREFIXES):
                    lines.append(token)

        except Exception as e:
            failures += 1
            print(f"Fetch failed: {url} -> {e}", file=sys.stderr)

    if failures == len(sources):
        print("All sources failed; keeping previous output.", file=sys.stderr)
        sys.exit(2)

    # De-duplicate
    seen = set()
    merged = []
    for ln in lines:
        k = hashlib.sha256(ln.encode("utf-8", "ignore")).hexdigest()
        if k in seen:
            continue
        seen.add(k)
        merged.append(ln)

    # One config per line, then base64 encode
    merged_text = "\n".join(merged) + ("\n" if merged else "")
    out = b64encode_clean(merged_text) if merged_text.strip() else ""

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT_PATH.with_suffix(".tmp")
    tmp.write_text(out, encoding="utf-8")
    os.replace(tmp, OUT_PATH)

    print(f"Total entries written: {len(merged)} -> {OUT_PATH}")

if __name__ == "__main__":
    main()
PY
  chmod +x "$APP_DIR/agg.py"
}

write_systemd() {
  cat >"$SVC" <<EOF
[Unit]
Description=V2Ray subscription aggregator
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${APP_DIR}/agg.py
EOF

  # timer initial interval based on config default; menu can update later
  cat >"$TMR" <<EOF
[Unit]
Description=Run V2Ray subscription aggregator every ${DEFAULT_INTERVAL} minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=${DEFAULT_INTERVAL}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

write_nginx() {
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat >"$NG_AV" <<EOF
server {
    listen ${DEFAULT_PORT};
    server_name _;

    location ${DEFAULT_PATH} {
        default_type text/plain;
        alias ${OUT_FILE};
        add_header Cache-Control "no-store";
    }
}
EOF
  ln -sf "$NG_AV" "$NG_EN"
}

write_manager() {
  cat >"$BIN" <<PY
#!/usr/bin/env python3
VERSION = "${VERSION}"

import base64
import json
import os
import re
import shlex
import socket
import subprocess
from pathlib import Path
from urllib.parse import urlparse

APP_DIR = Path("/opt/v2subagg")
WWW_DIR = Path("/var/www/sub")
OUT_FILE = WWW_DIR / "1111.text"
CONFIG_FILE = Path("/etc/v2subagg/config.json")

SYSTEMD_SERVICE = Path("/etc/systemd/system/v2subagg.service")
SYSTEMD_TIMER = Path("/etc/systemd/system/v2subagg.timer")
NGINX_SITE_AVAIL = Path("/etc/nginx/sites-available/sub")
NGINX_SITE_ENABLED = Path("/etc/nginx/sites-enabled/sub")

DEFAULT_INTERVAL_MIN = 10
DEFAULT_PORT = 8443
DEFAULT_SCHEME = "http"
DEFAULT_PATH = "/1111.text"

def run(cmd, check=False, capture=False):
    if isinstance(cmd, str):
        cmd_list = shlex.split(cmd)
    else:
        cmd_list = cmd
    return subprocess.run(
        cmd_list,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )

def load_config():
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {
        "sources": [],
        "interval_minutes": DEFAULT_INTERVAL_MIN,
        "scheme": DEFAULT_SCHEME,
        "port": DEFAULT_PORT,
        "path": DEFAULT_PATH,
        "host": "",
    }

def save_config(cfg):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")

def validate_url(u: str) -> bool:
    try:
        p = urlparse(u.strip())
        return p.scheme in ("http", "https") and bool(p.netloc)
    except Exception:
        return False

def get_server_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def merged_url(cfg):
    host = cfg.get("host") or get_server_ip()
    scheme = cfg.get("scheme", DEFAULT_SCHEME)
    port = int(cfg.get("port", DEFAULT_PORT))
    path = cfg.get("path", DEFAULT_PATH)
    if (scheme == "http" and port == 80) or (scheme == "https" and port == 443):
        return f"{scheme}://{host}{path}"
    return f"{scheme}://{host}:{port}{path}"

def show_merged_file():
    if not OUT_FILE.exists():
        print("Merged file not found yet:", OUT_FILE)
        return
    data_b64 = OUT_FILE.read_text(encoding="utf-8", errors="ignore").strip()
    print("\\n--- RAW (Base64) ---")
    print(data_b64 if data_b64 else "(empty)")
    if not data_b64:
        return

    b = data_b64.encode("utf-8")
    b += b"=" * ((-len(b)) % 4)
    try:
        decoded = base64.b64decode(b).decode("utf-8", "ignore")
        print("\\n--- DECODED (one per line) ---")
        print(decoded)
    except Exception:
        print("\\n(Decode failed)")

def update_timer_interval(cfg, minutes: int):
    minutes = max(1, int(minutes))
    cfg["interval_minutes"] = minutes
    save_config(cfg)

    timer_text = f\"\"\"[Unit]
Description=Run V2Ray subscription aggregator every {minutes} minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec={minutes}min
Persistent=true

[Install]
WantedBy=timers.target
\"\"\"
    SYSTEMD_TIMER.write_text(timer_text, encoding="utf-8")
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "restart", "v2subagg.timer"])
    print("Saved interval and restarted timer.")

def manual_update():
    print("Updating now...")
    run(["systemctl", "start", "v2subagg.service"])
    out = run(["journalctl", "-u", "v2subagg.service", "-n", "3", "--no-pager"], capture=True)
    if out.stdout:
        print(out.stdout.strip())
    print("Manual refresh triggered.")

def service_status():
    print(run(["systemctl", "status", "v2subagg.timer", "--no-pager"], capture=True).stdout or "")
    print(run(["systemctl", "status", "v2subagg.service", "--no-pager"], capture=True).stdout or "")

def add_subscription(cfg):
    u = input("Enter subscription URL (http/https): ").strip()
    if not validate_url(u):
        print("Invalid URL.")
        return
    if u in cfg.get("sources", []):
        print("Already added.")
        return
    cfg["sources"].append(u)
    save_config(cfg)
    manual_update()

def list_subscriptions(cfg):
    src = cfg.get("sources", [])
    if not src:
        print("No URLs.")
        return
    for i, u in enumerate(src, 1):
        print(f"{i}. {u}")

def remove_subscription(cfg):
    src = cfg.get("sources", [])
    if not src:
        print("Nothing to remove.")
        return
    for i, u in enumerate(src, 1):
        print(f"{i}. {u}")
    s = input("Number to remove: ").strip()
    if not re.fullmatch(r"\\d+", s):
        print("Invalid number.")
        return
    idx = int(s)
    if idx < 1 or idx > len(src):
        print("Out of range.")
        return
    removed = src.pop(idx - 1)
    cfg["sources"] = src
    save_config(cfg)
    print("Removed:", removed)
    manual_update()

def uninstall_everything():
    print("\\nUninstalling v2subagg (python/nginx kept)...")

    run(["systemctl", "stop", "v2subagg.timer"])
    run(["systemctl", "disable", "v2subagg.timer"])
    run(["systemctl", "stop", "v2subagg.service"])

    try:
        if SYSTEMD_TIMER.exists(): SYSTEMD_TIMER.unlink()
    except Exception:
        pass
    try:
        if SYSTEMD_SERVICE.exists(): SYSTEMD_SERVICE.unlink()
    except Exception:
        pass

    run(["systemctl", "daemon-reload"])

    try:
        if NGINX_SITE_ENABLED.exists() or NGINX_SITE_ENABLED.is_symlink():
            NGINX_SITE_ENABLED.unlink()
    except Exception:
        pass
    try:
        if NGINX_SITE_AVAIL.exists():
            NGINX_SITE_AVAIL.unlink()
    except Exception:
        pass

    run(["systemctl", "restart", "nginx"])

    run(["rm", "-rf", "/opt/v2subagg", "/etc/v2subagg", "/var/www/sub"])

    try:
        Path("/usr/local/bin/v2subagg").unlink()
    except Exception:
        pass

    print("Uninstall completed.")

def print_version_and_exit():
    print(f"v2subagg version {VERSION}")

def menu():
    print(f"\\n==== V2SubAgg v{VERSION} ====")
    print("1) Add subscription URL")
    print("2) List URLs")
    print("3) Show merged URL")
    print("4) Set update interval (minutes)")
    print("5) Service status")
    print("6) Remove subscription URL")
    print("7) Show merged file (raw + decoded)")
    print("8) Update now (manual refresh)")
    print("9) Uninstall")
    print("10) Exit")

def main():
    import sys
    if "--version" in sys.argv or "-v" in sys.argv:
        print_version_and_exit()
        return

    if os.geteuid() != 0:
        print("Run with sudo: sudo v2subagg")
        return

    while True:
        cfg = load_config()
        menu()
        ch = input("Select: ").strip()

        if ch == "1":
            add_subscription(cfg)
        elif ch == "2":
            list_subscriptions(cfg)
        elif ch == "3":
            print(merged_url(cfg))
        elif ch == "4":
            v = input("Minutes: ").strip()
            if not re.fullmatch(r"\\d+", v):
                print("Invalid.")
                continue
            update_timer_interval(cfg, int(v))
        elif ch == "5":
            service_status()
        elif ch == "6":
            remove_subscription(cfg)
        elif ch == "7":
            show_merged_file()
        elif ch == "8":
            manual_update()
        elif ch == "9":
            uninstall_everything()
            break
        elif ch == "10":
            break
        else:
            print("Invalid option.")

if __name__ == "__main__":
    main()
PY
  chmod +x "$BIN"
}

enable_services() {
  nginx -t
  systemctl daemon-reload
  systemctl enable --now v2subagg.timer >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (use sudo)."
    exit 1
  fi

  ensure_deps
  write_config_if_missing
  write_aggregator
  write_systemd
  write_nginx
  write_manager
  enable_services

  echo ""
  echo "Installed V2SubAgg v${VERSION}"
  echo "Run: sudo v2subagg"
  echo "Output file: ${OUT_FILE}"
  echo "Endpoint path: ${DEFAULT_PATH}"
}

main "$@"
