"""Server tests with a fake Vexcel and Matterport. No network, no keys.

Run:  cd server && ../.venv/bin/python -m unittest -v
"""
import json
import os
import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

os.environ.update(
    VEXCEL_API_KEY="test-key", MATTERPORT_API_KEY="k", MATTERPORT_API_TOKEN="t",
    MATTERPORT_MODEL_ID="model", MATTERPORT_MODEL_LAT="40.3491", MATTERPORT_MODEL_LON="-74.6554")
import main  # noqa: E402

INSIDE = {"id": 0, "lat": 40.34937, "lon": -74.65626}
OUTSIDE = {"id": 1, "lat": 29.76, "lon": -95.37}  # Houston
BOX = "POLYGON ((-74.65636 40.34946, -74.65613 40.34946, -74.65613 40.34929, -74.65636 40.34929, -74.65636 40.34946))"


def detection(features):
    return httpx.Response(200, json={"type": "FeatureCollection", "features": features})


FOUND = [{"type": "Feature", "properties": {"label": "crosswalk", "detections": [{"imageId": "ortho-1", "bbox": BOX, "confidence": 0.66}]}}]


class RouteIntelTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.detect = lambda: detection(FOUND)
        self.matterport = lambda: httpx.Response(200, json={"data": {"model": {
            "name": "Princeton - Rabinowitz Hall", "floors": [{}] * 3, "rooms": [{}] * 32}}})

        def handler(request):
            self.calls.append(request.url.path)
            if request.url.path.endswith("elements/detect"):
                self.assert_key(request)
                return self.detect()
            if request.url.path.endswith("ortho/extract"):
                return httpx.Response(200, content=b"\xff\xd8jpeg", headers={"content-type": "image/jpeg"})
            return self.matterport()

        main.app.state.client_factory = lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler))
        main.app.state.cache_dir = Path(tempfile.mkdtemp())
        main.app.state.retry_wait = 0
        self.client = TestClient(main.app)

    def assert_key(self, request):
        self.assertEqual(request.headers["x-api-key"], "test-key")

    def post(self, maneuvers, destination=None):
        response = self.client.post("/route-intel", json={"maneuvers": maneuvers, "destination": destination})
        self.assertEqual(response.status_code, 200)
        return response.json()

    def test_crosswalk_found_inside_the_box(self):
        result = self.post([INSIDE])["maneuvers"][0]
        self.assertEqual((result["status"], result["crosswalk"]), ("ok", True))
        self.assertEqual(len(result["boxes"]), 1)
        x, y, w, h = result["boxes"][0]
        self.assertTrue(0 <= x <= 1 and 0 <= y <= 1 and w > 0 and h > 0)
        # The aerial image was saved and can be fetched for the debug screen.
        self.assertEqual(self.client.get("/" + result["tile"]).status_code, 200)

    def test_outside_the_box_makes_no_call(self):
        result = self.post([OUTSIDE])["maneuvers"][0]
        self.assertEqual((result["status"], result["crosswalk"]), ("outside_box", False))
        self.assertEqual(self.calls, [])

    def test_no_detection_is_empty_not_a_claim(self):
        self.detect = lambda: detection([])
        result = self.post([INSIDE])["maneuvers"][0]
        self.assertEqual((result["status"], result["crosswalk"]), ("empty", False))

    def test_forbidden_rate_limited_and_timeout_degrade_quietly(self):
        for response, status in [(httpx.Response(403), "forbidden"), (httpx.Response(429), "rate_limited"),
                                 (httpx.Response(500), "error")]:
            self.detect = lambda r=response: r
            result = self.post([INSIDE])["maneuvers"][0]
            self.assertEqual((result["status"], result["crosswalk"]), (status, False))

        def slow():
            raise httpx.ReadTimeout("slow")
        self.detect = slow
        self.assertEqual(self.post([INSIDE])["maneuvers"][0]["status"], "timeout")

    def test_rate_limit_is_retried(self):
        answers = [httpx.Response(429), detection(FOUND)]
        self.detect = lambda: answers.pop(0)
        self.assertEqual(self.post([INSIDE])["maneuvers"][0]["status"], "ok")

    def test_second_request_uses_the_cache(self):
        self.post([INSIDE])
        before = len(self.calls)
        again = self.post([INSIDE])["maneuvers"][0]
        self.assertEqual(len(self.calls), before)
        self.assertTrue(again["crosswalk"])

    def test_failures_are_not_cached(self):
        self.detect = lambda: httpx.Response(403)
        self.post([INSIDE])
        self.detect = lambda: detection(FOUND)
        self.assertEqual(self.post([INSIDE])["maneuvers"][0]["status"], "ok")

    def test_arrival_blurb_only_at_the_building(self):
        near = {"name": "Rabinowitz Hall", "lat": 40.3491, "lon": -74.6555}
        self.assertEqual(self.post([], near)["arrival"], {"blurb": "Rabinowitz Hall. Three floors, 32 rooms."})
        far = {"name": "McDonald's", "lat": 40.36, "lon": -74.66}
        self.assertIsNone(self.post([], far)["arrival"])

    def test_arrival_blurb_failure_is_null(self):
        self.matterport = lambda: httpx.Response(401)
        near = {"name": "Rabinowitz Hall", "lat": 40.3491, "lon": -74.6555}
        self.assertIsNone(self.post([], near)["arrival"])

    def test_responses_never_contain_keys(self):
        text = json.dumps(self.post([INSIDE], {"name": "x", "lat": 40.3491, "lon": -74.6555}))
        self.assertNotIn("test-key", text)
        self.assertNotIn("model", text.replace("model-input", ""))


if __name__ == "__main__":
    unittest.main()
