#!/usr/bin/env bash
set -euo pipefail
set +H

VERSION="1.2.0"

APP_DIR="/opt/v2subagg"
ETC_DIR="/etc/v2subagg"
WWW_DIR="/var/www/sub"
OUT_FILE="$WWW_DIR/merged.txt"

SVC="/etc/systemd/system/v2subagg.service"
TMR="/etc/systemd/system/v2subagg.timer"

NG_AV="/etc/nginx/sites-available/sub"
NG_EN="/etc/nginx/sites-enabled/sub"

BIN="/usr/local/bin/v2subagg"

DEFAULT_PORT="8443"
DEFAULT_PATH="/merged"
DEFAULT_INTERVAL="10"

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
    echo "Unsupported package manager. Install python3 and nginx manually."
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

write_files() {

  mkdir -p "$APP_DIR" "$ETC_DIR" "$WWW_DIR" /etc/nginx/sites-available /etc/nginx/sites-enabled

  if [[ ! -f "$ETC_DIR/config.json" ]]; then
cat >"$ETC_DIR/config.json" <<EOF
{
  "sources": [],
  "interval_minutes": ${DEFAULT_INTERVAL},
  "scheme": "http",
  "port": ${DEFAULT_PORT},
  "path": "${DEFAULT_PATH}",
  "host": ""
}
EOF
  fi

cat >"$APP_DIR/agg.py" <<'PY'
#!/usr/bin/env python3
import base64, hashlib, json, os, re, sys
from pathlib import Path
from urllib.request import Request, urlopen

CONFIG = Path("/etc/v2subagg/config.json")
OUT_PATH = Path("/var/www/sub/merged.txt")
UA = "Mozilla/5.0 (sub-aggregator)"
PREFIXES = ("vmess://","vless://","trojan://","ss://","hysteria://","hy2://","tuic://")

def fetch(url: str) -> bytes:
    req = Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
    with urlopen(req, timeout=30) as r:
        return r.read()

def b64decode_relaxed(data: bytes) -> str:
    s = data.strip().replace(b"\n", b"").replace(b"\r", b"")
    s += b"=" * ((-len(s)) % 4)
    try:
        txt = base64.b64decode(s).decode("utf-8", "ignore")
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
        sys.exit(1)

    lines = []
    failures = 0

    for url in sources:
        try:
            content = fetch(url)
            decoded = b64decode_relaxed(content)

            for token in re.split(r"\s+", decoded.strip()):
                token = token.strip()
                if token and token.startswith(PREFIXES):
                    lines.append(token)

        except Exception:
            failures += 1

    if failures == len(sources):
        sys.exit(2)

    seen = set()
    merged = []
    for ln in lines:
        k = hashlib.sha256(ln.encode("utf-8", "ignore")).hexdigest()
        if k in seen:
            continue
        seen.add(k)
        merged.append(ln)

    merged_text = "\n".join(merged) + ("\n" if merged else "")
    out = b64encode_clean(merged_text) if merged_text.strip() else ""

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT_PATH.with_suffix(".tmp")
    tmp.write_text(out, encoding="utf-8")
    os.replace(tmp, OUT_PATH)

    print(f"Total entries written: {len(merged)}")

if __name__ == "__main__":
    main()
PY

  chmod +x "$APP_DIR/agg.py"

cat >"$BIN" <<PY
#!/usr/bin/env python3
VERSION = "${VERSION}"

import base64, json, os, re, shlex, socket, subprocess
from pathlib import Path
from urllib.parse import urlparse

CFG = Path("/etc/v2subagg/config.json")
OUT = Path("/var/www/sub/merged.txt")

def run(cmd, cap=False):
    if isinstance(cmd, str):
        cmd = shlex.split(cmd)
    return subprocess.run(cmd, text=True,
                          stdout=subprocess.PIPE if cap else None)

def load():
    return json.loads(CFG.read_text(encoding="utf-8"))

def save(c):
    CFG.write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding="utf-8")

def ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("1.1.1.1", 80))
    i = s.getsockname()[0]
    s.close()
    return i

def merged_url(c):
    host = c.get("host") or ip()
    return f"http://{host}:8443/merged"

def show_raw_and_decoded():
    if not OUT.exists():
        print("No merged file yet.")
        return
    data = OUT.read_text().strip()
    print("\n--- RAW ---")
    print(data)
    if not data:
        return
    b = data.encode()
    b += b"="*((-len(b))%4)
    print("\n--- DECODED ---")
    print(base64.b64decode(b).decode("utf-8","ignore"))

def uninstall():
    run("systemctl stop v2subagg.timer")
    run("systemctl disable v2subagg.timer")
    run("rm -rf /opt/v2subagg /etc/v2subagg /var/www/sub")
    run("rm -f /etc/systemd/system/v2subagg.*")
    run("rm -f /etc/nginx/sites-enabled/sub")
    run("rm -f /etc/nginx/sites-available/sub")
    run("systemctl daemon-reload")
    run("systemctl restart nginx")
    print("Uninstalled.")

def menu():
    print(f"\n==== V2SubAgg v{VERSION} ====")
    print("1) Add subscription URL")
    print("2) List URLs")
    print("3) Show merged URL")
    print("4) Update now")
    print("5) Show merged file")
    print("6) Uninstall")
    print("7) Exit")

def main():
    if os.geteuid() != 0:
        print("Run with sudo.")
        return

    while True:
        c = load()
        menu()
        ch = input("Select: ").strip()

        if ch == "1":
            u = input("Enter subscription URL: ").strip()
            c["sources"].append(u)
            save(c)
            run("systemctl start v2subagg.service")
            print("Added and updated.")

        elif ch == "2":
            print("\n".join(c.get("sources", [])) or "No URLs.")

        elif ch == "3":
            print(merged_url(c))

        elif ch == "4":
            print("Updating...")
            run("systemctl start v2subagg.service")
            print("Done.")

        elif ch == "5":
            show_raw_and_decoded()

        elif ch == "6":
            uninstall()
            break

        elif ch == "7":
            break

        else:
            print("Invalid.")

if __name__ == "__main__":
    main()
PY

  chmod +x "$BIN"

cat >"$SVC" <<EOF
[Unit]
Description=V2Ray subscription aggregator
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${APP_DIR}/agg.py
EOF

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

enable_services() {
  nginx -t
  systemctl daemon-reload
  systemctl enable --now v2subagg.timer
  systemctl restart nginx
}

main() {
  [[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
  ensure_deps
  write_files
  enable_services
  echo ""
  echo "Installed V2SubAgg v${VERSION}"
  echo "Run: sudo v2subagg"
}

main "$@"
