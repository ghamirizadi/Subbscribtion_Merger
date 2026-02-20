#!/usr/bin/env bash
set -euo pipefail
set +H

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
    echo "Unsupported package manager. Please install python3 + nginx manually."
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

  # Aggregator (Base64 output, splits by ANY whitespace, keeps one config per line)
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
        # If it looks like decoded links, return it
        if "://" in txt:
            return txt
    except Exception:
        pass
    return data.decode("utf-8", "ignore")

def b64encode_clean(text: str) -> str:
    raw = text.strip().encode("utf-8")
    return base64.b64encode(raw).decode("ascii")

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
            # Split by ANY whitespace (spaces/newlines/tabs)
            for token in re.split(r"\s+", decoded.strip()):
                token = token.strip()
                if token and token.startswith(PREFIXES):
                    lines.append(token)
        except Exception:
            failures += 1

    if failures == len(sources):
        # keep previous output
        sys.exit(2)

    seen = set()
    merged = []
    for ln in lines:
        k = hashlib.sha256(ln.encode("utf-8", "ignore")).hexdigest()
        if k in seen:
            continue
        seen.add(k)
        merged.append(ln)

    # One config per line
    merged_text = "\n".join(merged) + ("\n" if merged else "")
    out = b64encode_clean(merged_text) if merged_text.strip() else ""

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT_PATH.with_suffix(".tmp")
    tmp.write_text(out, encoding="utf-8")
    os.replace(tmp, OUT_PATH)

if __name__ == "__main__":
    main()
PY
  chmod +x "$APP_DIR/agg.py"

  # systemd
  cat >"$SVC" <<EOF
[Unit]
Description=V2Ray subscription aggregator
After=network-online.target
Wants=network-online.target

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

  # nginx
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

  # Manager menu (includes Uninstall + Show merged file)
  cat >"$BIN" <<'PY'
#!/usr/bin/env python3
import base64, json, os, re, shlex, socket, subprocess
from pathlib import Path
from urllib.parse import urlparse

CFG = Path("/etc/v2subagg/config.json")
OUT = Path("/var/www/sub/merged.txt")
TMR = Path("/etc/systemd/system/v2subagg.timer")
SVC = Path("/etc/systemd/system/v2subagg.service")
NG_AV = Path("/etc/nginx/sites-available/sub")
NG_EN = Path("/etc/nginx/sites-enabled/sub")

def run(cmd, cap=False):
    if isinstance(cmd, str):
        cmd = shlex.split(cmd)
    return subprocess.run(cmd, text=True,
                          stdout=subprocess.PIPE if cap else None,
                          stderr=subprocess.PIPE if cap else None)

def load():
    return json.loads(CFG.read_text(encoding="utf-8"))

def save(c):
    CFG.write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding="utf-8")

def ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        i = s.getsockname()[0]
        s.close()
        return i
    except Exception:
        return "127.0.0.1"

def merged_url(c):
    host = c.get("host") or ip()
    scheme = c.get("scheme", "http")
    port = int(c.get("port", 8443))
    path = c.get("path", "/merged")
    return f"{scheme}://{host}:{port}{path}"

def validate_url(u: str) -> bool:
    try:
        p = urlparse(u.strip())
        return p.scheme in ("http","https") and bool(p.netloc)
    except Exception:
        return False

def show_raw_and_decoded():
    if not OUT.exists():
        print("Merged file not found yet:", OUT)
        return
    data = OUT.read_text(encoding="utf-8", errors="ignore").strip()
    print("\n--- RAW merged.txt (Base64) ---")
    print(data if data else "(empty)")
    if not data:
        return
    b = data.encode("utf-8")
    b += b"=" * ((-len(b)) % 4)
    try:
        decoded = base64.b64decode(b).decode("utf-8","ignore")
        print("\n--- DECODED merged subscription (one per line) ---")
        print(decoded)
    except Exception:
        print("\n(Decode failed)")

def uninstall():
    print("\nUninstalling v2subagg (python/nginx kept)...")
    run(["systemctl","stop","v2subagg.timer"], cap=False)
    run(["systemctl","disable","v2subagg.timer"], cap=False)
    run(["systemctl","stop","v2subagg.service"], cap=False)

    run(["rm","-f", str(SVC), str(TMR)], cap=False)
    run(["systemctl","daemon-reload"], cap=False)

    run(["rm","-f", str(NG_EN), str(NG_AV)], cap=False)
    run(["systemctl","restart","nginx"], cap=False)

    run(["rm","-rf","/opt/v2subagg","/etc/v2subagg","/var/www/sub"], cap=False)

    try:
        Path("/usr/local/bin/v2subagg").unlink()
    except Exception:
        pass

    print("Uninstall completed.")

def menu():
    print("\n==== V2Ray Subscription Aggregator ====")
    print("1) Add subscription URL")
    print("2) List URLs")
    print("3) Show merged URL")
    print("4) Set update interval (minutes)")
    print("5) Service status")
    print("6) Remove URL")
    print("7) Show merged file (raw + decoded)")
    print("8) Uninstall")
    print("9) Exit")

def main():
    if os.geteuid() != 0:
        print("Run with sudo: sudo v2subagg")
        return

    while True:
        c = load()
        menu()
        ch = input("Select: ").strip()

        if ch == "1":
            u = input("Enter subscription URL (http/https): ").strip()
            if not validate_url(u):
                print("Invalid URL.")
                continue
            if u in c.get("sources", []):
                print("Already added.")
                continue
            c["sources"].append(u)
            save(c)
            run(["systemctl","start","v2subagg.service"])
            print("Added & refresh triggered.")

        elif ch == "2":
            src = c.get("sources", [])
            print("\n".join(src) if src else "No URLs.")

        elif ch == "3":
            print(merged_url(c))

        elif ch == "4":
            v = input("Minutes: ").strip()
            if not re.fullmatch(r"\d+", v):
                print("Invalid.")
                continue
            m = max(1, int(v))
            c["interval_minutes"] = m
            save(c)

            TMR.write_text(f"""[Unit]
Description=Run V2Ray subscription aggregator every {m} minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec={m}min
Persistent=true

[Install]
WantedBy=timers.target
""", encoding="utf-8")

            run(["systemctl","daemon-reload"])
            run(["systemctl","restart","v2subagg.timer"])
            print("Saved.")

        elif ch == "5":
            print(run(["systemctl","status","v2subagg.timer","--no-pager"], cap=True).stdout)
            print(run(["systemctl","status","v2subagg.service","--no-pager"], cap=True).stdout)

        elif ch == "6":
            src = c.get("sources", [])
            if not src:
                print("Nothing to remove.")
                continue
            for i,u in enumerate(src,1):
                print(f"{i}. {u}")
            n = input("Number: ").strip()
            if not re.fullmatch(r"\d+", n):
                print("Invalid.")
                continue
            idx = int(n)
            if idx < 1 or idx > len(src):
                print("Out of range.")
                continue
            rem = src.pop(idx-1)
            c["sources"] = src
            save(c)
            run(["systemctl","start","v2subagg.service"])
            print("Removed:", rem)

        elif ch == "7":
            show_raw_and_decoded()

        elif ch == "8":
            uninstall()
            break

        elif ch == "9":
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
  write_files
  enable_services

  echo ""
  echo "Installed."
  echo "Run: sudo v2subagg"
  echo "Merged URL will be shown in menu (option 3)."
}

main "$@"
