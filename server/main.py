"""HeadsUp route-intel server.

Runs on a laptop so the Vexcel and Matterport keys never reach the phone. The phone calls it
ONCE before a walk; nothing here is in the hazard loop.

  POST /route-intel   crosswalk check at each turn (Vexcel aerial imagery) + arrival blurb (Matterport)
  GET  /tiles/{key}   the aerial image used for a turn, for the debug screen
  GET  /health

Run:  cd server && ../.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000

Rules kept here:
- A crosswalk is reported only when the detector found one. Every failure means "say nothing
  extra"; nothing here ever claims there is NO crosswalk.
- Keys come from server/.env and are never logged or returned.
- Aerial images show paint from a past flight, not traffic or signals.
"""
import asyncio
import json
import math
import os
import re
from pathlib import Path

import httpx
from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache"
VEXCEL = "https://api.vexcelgroup.com/v2"
MATTERPORT = "https://api.matterport.com/api/models/graph"
LAYERS = "urban,urban-r,wide-area,urban-g"
# The area the event's Vexcel key covers. Outside it the API answers 403, so we do not ask.
PRINCETON_BOX = {"west": -74.694, "east": -74.598, "south": 40.316, "north": 40.371}
SQUARE_METRES = 60.0
THRESHOLD = 0.5
ARRIVAL_METRES = 60.0


def load_env():
    env = HERE / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.split("=", 1)
                os.environ.setdefault(name.strip(), value.strip())


load_env()
app = FastAPI(title="HeadsUp route intel")
# Replaced in tests with a client that talks to a fake Vexcel/Matterport.
app.state.client_factory = lambda: httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=5.0))
app.state.cache_dir = CACHE
app.state.retry_wait = 1.0


class Point(BaseModel):
    id: int
    lat: float
    lon: float


class Destination(BaseModel):
    name: str
    lat: float
    lon: float


class IntelRequest(BaseModel):
    maneuvers: list[Point] = []
    destination: Destination | None = None


def square(lat, lon, side=SQUARE_METRES):
    """West, south, east, north of a square of `side` metres centred on a point."""
    dlat = side / 2 / 111_320
    dlon = side / 2 / (111_320 * math.cos(math.radians(lat)))
    return lon - dlon, lat - dlat, lon + dlon, lat + dlat


def wkt(bounds):
    w, s, e, n = bounds
    return f"POLYGON(({w} {s},{e} {s},{e} {n},{w} {n},{w} {s}))"


def in_box(lat, lon):
    b = PRINCETON_BOX
    return b["west"] <= lon <= b["east"] and b["south"] <= lat <= b["north"]


def metres(lat1, lon1, lat2, lon2):
    north = (lat2 - lat1) * 111_320
    east = (lon2 - lon1) * 111_320 * math.cos(math.radians(lat1))
    return math.hypot(north, east)


def key_for(lat, lon):
    """Cache key: the point rounded to about 1 m, so a repeated route makes no new calls."""
    return f"{lat:.5f}_{lon:.5f}".replace("-", "m").replace(".", "p")


def box_in_square(bbox_wkt, bounds):
    """A detection box as [x, y, width, height], each 0–1 of the image, origin top-left."""
    numbers = [float(n) for n in re.findall(r"-?\d+\.?\d*(?:[eE]-?\d+)?", bbox_wkt)]
    lons, lats = numbers[0::2], numbers[1::2]
    if not lons or not lats:
        return None
    w, s, e, n = bounds
    x0, x1 = (min(lons) - w) / (e - w), (max(lons) - w) / (e - w)
    y0, y1 = (n - max(lats)) / (n - s), (n - min(lats)) / (n - s)
    clamp = lambda v: max(0.0, min(1.0, v))
    x0, x1, y0, y1 = clamp(x0), clamp(x1), clamp(y0), clamp(y1)
    return [round(x0, 4), round(y0, 4), round(x1 - x0, 4), round(y1 - y0, 4)]


async def vexcel_post(client, path, body):
    """POST to Vexcel. Returns (status, response). Retries 429 a few times, then gives up."""
    headers = {"X-API-KEY": os.environ.get("VEXCEL_API_KEY", "")}
    response = None
    for attempt in range(3):
        response = await client.post(f"{VEXCEL}/{path}", json=body, headers=headers)
        if response.status_code != 429:
            break
        await asyncio.sleep(app.state.retry_wait * (2 ** attempt))
    return response.status_code, response


STATUS_FOR = {401: "forbidden", 403: "forbidden", 404: "empty", 429: "rate_limited"}


async def crosswalk_at(client, point: Point):
    """One turn: is a marked crosswalk visible in the aerial image around it?"""
    result = {"id": point.id, "status": "error", "crosswalk": False, "boxes": [], "tile": None}
    if not in_box(point.lat, point.lon):
        return {**result, "status": "outside_box"}

    key = key_for(point.lat, point.lon)
    cache_file = app.state.cache_dir / "intel" / f"{key}.json"
    if cache_file.exists():
        return {**json.loads(cache_file.read_text()), "id": point.id}

    bounds = square(point.lat, point.lon)
    area = wkt(bounds)
    image_request = {"layer": LAYERS, "srid": 4326, "wkt": area, "crop": "bounding_box"}
    try:
        status, response = await vexcel_post(client, "elements/detect", {
            "wkt": area, "srid": 4326, "buffer-meter": 0,
            "images": [{"endpoint": "ortho/extract", "request": image_request}],
            "model-input": {
                "elements": [{"label": "crosswalk", "model": "sam3", "detection-threshold": THRESHOLD}],
                "include": ["bbox", "confidence"],
            },
        })
        if status != 200:
            return {**result, "status": STATUS_FOR.get(status, "error")}
        features = response.json().get("features") or []
        boxes = []
        for feature in features:
            for detection in (feature.get("properties") or {}).get("detections") or []:
                box = box_in_square(detection.get("bbox") or "", bounds)
                if box:
                    boxes.append(box)
        result.update(status="ok" if boxes else "empty", crosswalk=bool(boxes), boxes=boxes)

        # The image is only for the debug screen. If it fails, the detection result still stands.
        status, image = await vexcel_post(client, "ortho/extract", {
            **image_request, "destination-dimensions": "600,600", "image-format": "jpeg"})
        if status == 200 and image.headers.get("content-type", "").startswith("image/"):
            tiles = app.state.cache_dir / "tiles"
            tiles.mkdir(parents=True, exist_ok=True)
            (tiles / f"{key}.jpg").write_bytes(image.content)
            result["tile"] = f"tiles/{key}.jpg"
    except httpx.TimeoutException:
        return {**result, "status": "timeout"}
    except (httpx.HTTPError, ValueError):
        return {**result, "status": "error"}

    # Only settled answers are cached. A failure is tried again next time.
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps({k: v for k, v in result.items() if k != "id"}))
    return result


NUMBER_WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]


def count(n, noun):
    word = NUMBER_WORDS[n] if 0 <= n < len(NUMBER_WORDS) else str(n)
    return f"{word} {noun}{'' if n == 1 else 's'}"


async def arrival_blurb(client, destination: Destination | None):
    """A short description of the building, from its Matterport model, when the destination is it."""
    try:
        model_lat = float(os.environ["MATTERPORT_MODEL_LAT"])
        model_lon = float(os.environ["MATTERPORT_MODEL_LON"])
        model_id = os.environ["MATTERPORT_MODEL_ID"]
        auth = (os.environ["MATTERPORT_API_KEY"], os.environ["MATTERPORT_API_TOKEN"])
    except (KeyError, ValueError):
        return None
    if destination is None or metres(destination.lat, destination.lon, model_lat, model_lon) > ARRIVAL_METRES:
        return None
    cache_file = app.state.cache_dir / "intel" / "arrival.json"
    if cache_file.exists():
        return json.loads(cache_file.read_text())
    query = "query($id: ID!) { model(id: $id) { name floors { id } rooms { id } } }"
    try:
        response = await client.post(MATTERPORT, json={"query": query, "variables": {"id": model_id}}, auth=auth)
        if response.status_code != 200:
            return None
        model = (response.json().get("data") or {}).get("model")
        if not model:
            return None
    except (httpx.HTTPError, ValueError):
        return None
    # "Princeton - Rabinowitz Hall" → "Rabinowitz Hall"
    name = (model.get("name") or destination.name).split(" - ")[-1].strip()
    floors, rooms = len(model.get("floors") or []), len(model.get("rooms") or [])
    parts = [p for p in [count(floors, "floor") if floors else None, count(rooms, "room") if rooms else None] if p]
    blurb = {"blurb": f"{name}. {', '.join(parts).capitalize()}." if parts else f"{name}."}
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(blurb))
    return blurb


@app.get("/health")
async def health():
    return {"ok": True, "vexcel_key": bool(os.environ.get("VEXCEL_API_KEY")),
            "matterport_key": bool(os.environ.get("MATTERPORT_API_KEY"))}


@app.post("/route-intel")
async def route_intel(request: IntelRequest):
    limit = asyncio.Semaphore(4)

    async def one(client, point):
        async with limit:
            return await crosswalk_at(client, point)

    async with app.state.client_factory() as client:
        maneuvers = await asyncio.gather(*(one(client, p) for p in request.maneuvers[:40]))
        arrival = await arrival_blurb(client, request.destination)
    return {"maneuvers": list(maneuvers), "arrival": arrival}


@app.get("/tiles/{name}")
async def tile(name: str):
    if not re.fullmatch(r"[0-9a-z_]+\.jpg", name):
        return JSONResponse({"error": "not found"}, status_code=404)
    path = app.state.cache_dir / "tiles" / name
    if not path.exists():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(path, media_type="image/jpeg")
