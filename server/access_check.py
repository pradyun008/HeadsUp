"""Phase 0 access check: one small Vexcel ortho call and one Matterport model query.

Run: python3 server/access_check.py
Prints status codes and content types only. Never prints keys, headers or model IDs.
Standard library only.
"""
import base64
import json
import math
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
VEXCEL = "https://api.vexcelgroup.com/v2"
MATTERPORT = "https://api.matterport.com/api/models/graph"
LAYERS = "urban,urban-r,wide-area,urban-g"


def load_env():
    for line in (HERE / ".env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            name, value = line.split("=", 1)
            os.environ.setdefault(name.strip(), value.strip())


def square_wkt(lat, lon, side_m):
    """A square of `side_m` metres centred on a point, as WKT (lon lat order)."""
    dlat = side_m / 2 / 111_320
    dlon = side_m / 2 / (111_320 * math.cos(math.radians(lat)))
    w, e, s, n = lon - dlon, lon + dlon, lat - dlat, lat + dlat
    return f"POLYGON(({w} {s},{e} {s},{e} {n},{w} {n},{w} {s}))"


def call(url, body, headers):
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json", **headers})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.headers.get("Content-Type", ""), response.read(), time.time() - started
    except urllib.error.HTTPError as error:
        return error.code, error.headers.get("Content-Type", ""), error.read(), time.time() - started
    except Exception as error:  # timeout, DNS, no network
        return None, type(error).__name__, str(error).encode(), time.time() - started


def check_vexcel():
    # Nassau Street at Witherspoon Street, inside the Princeton box.
    body = {"wkt": square_wkt(40.35035, -74.65935, 80), "srid": 4326, "layer": LAYERS,
            "crop": "bounding_box", "destination-dimensions": "800,800", "image-format": "jpeg"}
    status, kind, data, seconds = call(f"{VEXCEL}/ortho/extract", body, {"X-API-KEY": os.environ["VEXCEL_API_KEY"]})
    print(f"vexcel ortho/extract: status={status} type={kind} bytes={len(data)} {seconds:.1f}s")
    if status == 200 and kind.startswith("image/"):
        out = HERE / "cache" / "access_check_ortho.jpg"
        out.parent.mkdir(exist_ok=True)
        out.write_bytes(data)
        print(f"  saved {out.relative_to(HERE.parent)}")
    else:
        print("  body:", data[:300].decode(errors="replace"))


def check_matterport():
    auth = base64.b64encode(
        f"{os.environ['MATTERPORT_API_KEY']}:{os.environ['MATTERPORT_API_TOKEN']}".encode()).decode()
    query = """query Basics($id: ID!) { model(id: $id) {
      name geolocation { lat long } floors { id } rooms { id } panoLocations { id } } }"""
    body = {"query": query, "variables": {"id": os.environ["MATTERPORT_MODEL_ID"]}}
    status, kind, data, seconds = call(MATTERPORT, body, {"Authorization": f"Basic {auth}"})
    print(f"matterport model query: status={status} type={kind} bytes={len(data)} {seconds:.1f}s")
    try:
        payload = json.loads(data)
    except ValueError:
        print("  body:", data[:300].decode(errors="replace"))
        return
    for error in payload.get("errors") or []:
        print("  error:", str(error.get("message"))[:200])
    model = (payload.get("data") or {}).get("model")
    if model:
        print(f"  name={model.get('name')!r} geolocation={'yes' if model.get('geolocation') else 'no'}"
              f" floors={len(model.get('floors') or [])} rooms={len(model.get('rooms') or [])}"
              f" panos={len(model.get('panoLocations') or [])}")


if __name__ == "__main__":
    load_env()
    check_vexcel()
    check_matterport()
