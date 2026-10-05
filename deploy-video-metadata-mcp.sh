#!/bin/bash
# Deploys the Video Metadata MCP connector to Fly.io (London) and prints the URL to paste into Claude.
set -euo pipefail
DIR="$HOME/video-metadata-mcp"
mkdir -p "$DIR" && cd "$DIR"

cat > server.py <<'__EOF_server_py__'
"""URL Video Metadata MCP server.

Give it a direct MP4 URL plus new metadata. It fetches the video on the server,
strips the old metadata, writes the new tags with stream copy (no re-encode),
verifies the result with ffprobe and returns a public HTTPS URL to the new file.
"""

import ipaddress
import json
import os
import re
import secrets
import socket
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, PlainTextResponse

# ---------- config ----------
PORT = int(os.environ.get("PORT", "8000"))
SECRET = os.environ.get("MCP_SECRET", "")  # long random string; part of the connector URL
FILES_DIR = Path(os.environ.get("FILES_DIR", "/tmp/video-metadata-files"))
FILE_TTL_HOURS = float(os.environ.get("FILE_TTL_HOURS", "48"))
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(1024 * 1024 * 1024)))  # 1 GB
# Optional comma-separated host allowlist, e.g. "d8j0ntlcm91z4.cloudfront.net,cdn.adaptlypost.com"
ALLOWED_HOSTS = [h.strip().lower() for h in os.environ.get("ALLOWED_HOSTS", "").split(",") if h.strip()]

if not SECRET or len(SECRET) < 24:
    raise SystemExit("Set MCP_SECRET to a random string of at least 24 characters.")

FILES_DIR.mkdir(parents=True, exist_ok=True)


def public_base() -> str:
    base = os.environ.get("PUBLIC_BASE_URL")
    if not base and os.environ.get("RAILWAY_PUBLIC_DOMAIN"):
        base = "https://" + os.environ["RAILWAY_PUBLIC_DOMAIN"]
    if not base:
        base = f"http://localhost:{PORT}"
    return base.rstrip("/")


mcp = FastMCP(
    "Video Metadata",
    instructions=(
        "Rewrites the embedded metadata of an MP4 given only its URL, without re-encoding. "
        "Typical flow: inspect_video_url -> process_video_metadata -> (optional) verify_processed_video. "
        "process_video_metadata already verifies and returns the processed file's public URL."
    ),
    host="0.0.0.0",
    port=PORT,
    streamable_http_path=f"/{SECRET}/mcp",
    stateless_http=True,
    json_response=True,
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


# ---------- helpers ----------
def check_url(url: str) -> None:
    p = urllib.parse.urlparse(url)
    if p.scheme != "https" or not p.hostname:
        raise ValueError("video_url must be a direct https:// URL")
    host = p.hostname.lower()
    if ALLOWED_HOSTS and not any(host == h or host.endswith("." + h) for h in ALLOWED_HOSTS):
        raise ValueError(f"Host {host} is not in ALLOWED_HOSTS")
    for info in socket.getaddrinfo(host, 443):
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            raise ValueError("URL resolves to a private or internal address")


def safe_filename(name: str) -> str:
    stem = re.sub(r"\.mp4$", "", name.strip(), flags=re.I)
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip("-._").lower()[:120]
    return (stem or "video") + ".mp4"


def run(cmd: list[str], timeout: int = 600) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[-1500:])
    return r.stdout


def probe(target: str) -> dict:
    out = run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", target], 120)
    data = json.loads(out)
    fmt = data.get("format", {})
    streams = [
        {
            "index": s.get("index"),
            "type": s.get("codec_type"),
            "codec": s.get("codec_name"),
            "width": s.get("width"),
            "height": s.get("height"),
            "bit_rate": s.get("bit_rate"),
            "duration": s.get("duration"),
            "tags": s.get("tags", {}),
        }
        for s in data.get("streams", [])
    ]
    return {
        "duration": float(fmt.get("duration", 0) or 0),
        "size_bytes": int(fmt.get("size", 0) or 0),
        "format": fmt.get("format_name"),
        "tags": fmt.get("tags", {}),
        "streams": streams,
    }


def download(url: str, dest: Path) -> int:
    """Stream the source MP4 to a temp file (more reliable than ffmpeg reading HTTP directly)."""
    req = urllib.request.Request(url, headers={"User-Agent": "video-metadata-mcp/1.0"})
    total = 0
    with urllib.request.urlopen(req, timeout=60) as resp, open(dest, "wb") as f:
        while chunk := resp.read(1024 * 1024):
            total += len(chunk)
            if total > MAX_BYTES:
                raise ValueError("Video is larger than MAX_BYTES")
            f.write(chunk)
    if total == 0:
        raise RuntimeError("Downloaded file is empty")
    return total


def cleanup_old() -> None:
    cutoff = time.time() - FILE_TTL_HOURS * 3600
    for d in FILES_DIR.iterdir():
        try:
            if d.is_dir() and d.stat().st_mtime < cutoff:
                for f in d.iterdir():
                    f.unlink()
                d.rmdir()
        except OSError:
            pass


def compare(src: dict, out: dict, expected: dict) -> dict:
    src_codecs = [(s["type"], s["codec"]) for s in src["streams"]]
    out_codecs = [(s["type"], s["codec"]) for s in out["streams"]]
    tags = {k.lower(): v for k, v in out["tags"].items()}
    checks = {
        "codecs_unchanged": src_codecs == out_codecs,
        "resolution_unchanged": [(s["width"], s["height"]) for s in src["streams"]]
        == [(s["width"], s["height"]) for s in out["streams"]],
        "duration_unchanged": abs(src["duration"] - out["duration"]) < 0.1,
    }
    for key, val in expected.items():
        if val:
            checks[f"{key}_written"] = tags.get(key) == val
    allowed = {"major_brand", "minor_version", "compatible_brands"} | set(expected)
    leftovers = sorted(k for k in tags if k not in allowed)
    checks["old_metadata_removed"] = not leftovers
    checks["all_passed"] = all(checks.values())
    if leftovers:
        checks["unexpected_tags"] = leftovers
    return checks


# ---------- tools ----------
@mcp.tool()
def inspect_video_url(video_url: str) -> dict:
    """Read an MP4's existing container metadata, streams, codecs and duration straight from its URL."""
    check_url(video_url)
    return probe(video_url)


@mcp.tool()
def process_video_metadata(
    video_url: str,
    filename: str,
    title: str,
    description: str = "",
    comment: str = "",
    artist: str = "",
) -> dict:
    """Fetch the MP4 at video_url, remove all old metadata, write new title/description/comment/artist
    with stream copy (-c copy, no re-encode), verify with ffprobe, and return the processed file's URL.
    filename is the name the processed file will have (e.g. squat-proof-gym-shorts-01.mp4)."""
    check_url(video_url)
    cleanup_old()

    name = safe_filename(filename)
    job_dir = FILES_DIR / secrets.token_urlsafe(12)
    job_dir.mkdir()
    src_path = job_dir / ".source.mp4"
    out_path = job_dir / name

    download(video_url, src_path)
    before = probe(str(src_path))
    if not before["streams"]:
        raise RuntimeError("Source has no audio/video streams - is this a direct MP4 URL?")

    expected = {"title": title, "description": description, "comment": comment, "artist": artist}
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src_path),
           "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1",
           "-c", "copy", "-fflags", "+bitexact"]
    for key, val in expected.items():
        if val:
            cmd += ["-metadata", f"{key}={val}"]
    cmd += ["-movflags", "+faststart", str(out_path)]
    try:
        run(cmd, timeout=900)
        after = probe(str(out_path))
        checks = compare(before, after, expected)
        if not checks["all_passed"]:
            raise RuntimeError(f"Verification failed, no file returned: {checks}")
    except Exception:
        out_path.unlink(missing_ok=True)
        raise
    finally:
        src_path.unlink(missing_ok=True)

    url = f"{public_base()}/files/{job_dir.name}/{name}"
    return {
        "processed_url": url,
        "filename": name,
        "expires_in_hours": FILE_TTL_HOURS,
        "re_encoded": False,
        "checks": checks,
        "metadata_before": before["tags"],
        "metadata_after": after["tags"],
        "streams": [{"type": s["type"], "codec": s["codec"], "width": s["width"], "height": s["height"]}
                    for s in after["streams"]],
        "duration_seconds": after["duration"],
        "size_bytes": after["size_bytes"],
    }


@mcp.tool()
def verify_processed_video(
    processed_url: str,
    original_url: str = "",
    title: str = "",
    description: str = "",
    comment: str = "",
    artist: str = "",
) -> dict:
    """Re-check a processed MP4: tags match what was expected, old metadata gone, and (if original_url
    is given) codecs, resolution and duration are unchanged from the original."""
    check_url(processed_url)
    out = probe(processed_url)
    expected = {"title": title, "description": description, "comment": comment, "artist": artist}
    result = {"metadata": out["tags"], "streams": out["streams"], "duration_seconds": out["duration"]}
    if original_url:
        check_url(original_url)
        result["checks"] = compare(probe(original_url), out, expected)
    return result


# ---------- file serving + health ----------
@mcp.custom_route("/files/{job}/{name}", methods=["GET", "HEAD"])
async def serve_file(request: Request):
    job, name = request.path_params["job"], request.path_params["name"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,40}", job) or "/" in name or name.startswith("."):
        return PlainTextResponse("Not found", status_code=404)
    path = FILES_DIR / job / name
    if not path.is_file():
        return PlainTextResponse("Not found", status_code=404)
    return FileResponse(path, media_type="video/mp4", filename=name)


@mcp.custom_route("/health", methods=["GET"])
async def health(request: Request):
    return JSONResponse({"ok": True})


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
__EOF_server_py__

cat > requirements.txt <<'__EOF_requirements_txt__'
mcp>=1.12,<2
uvicorn>=0.30
__EOF_requirements_txt__

cat > Dockerfile <<'__EOF_Dockerfile__'
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
ENV PORT=8000 FILES_DIR=/data/files
EXPOSE 8000
CMD ["python", "server.py"]
__EOF_Dockerfile__

cat > fly.toml <<'__EOF_fly_toml__'
primary_region = "lhr"

[build]

[http_service]
  internal_port = 8000
  force_https = true
  auto_stop_machines = "off"
  auto_start_machines = true
  min_machines_running = 1

[checks]
  [checks.health]
    type = "http"
    port = 8000
    path = "/health"
    interval = "30s"
    timeout = "5s"

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
__EOF_fly_toml__

# --- Fly CLI + login ---
command -v fly >/dev/null || brew install flyctl
fly auth whoami >/dev/null 2>&1 || fly auth login

# --- app name + secret (reused on re-runs) ---
[ -f .app_name ] || echo "video-metadata-$(openssl rand -hex 3)" > .app_name
[ -f .mcp_secret ] || openssl rand -hex 24 > .mcp_secret
APP=$(cat .app_name); SECRET=$(cat .mcp_secret)
chmod 600 .mcp_secret

fly status -a "$APP" >/dev/null 2>&1 || fly apps create "$APP"
fly secrets set MCP_SECRET="$SECRET" PUBLIC_BASE_URL="https://$APP.fly.dev" -a "$APP" --stage
fly deploy -a "$APP" --ha=false --remote-only

echo; echo "Waiting for the server..."
for i in $(seq 1 30); do curl -sf "https://$APP.fly.dev/health" >/dev/null && break; sleep 4; done
curl -s "https://$APP.fly.dev/health"; echo
URL="https://$APP.fly.dev/$SECRET/mcp"
echo "$URL" > connector_url.txt
echo
echo "=========================================================="
echo " Paste this into Claude > Settings > Connectors > Add custom connector:"
echo " $URL"
echo " (saved to $DIR/connector_url.txt - keep it private, it acts as the password)"
echo "=========================================================="
command -v pbcopy >/dev/null && printf "%s" "$URL" | pbcopy && echo " Copied to clipboard."
