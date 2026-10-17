#!/usr/bin/env python3
"""
OpenTrack agent — runs on YOUR OWN laptop to help you locate it if lost
or stolen. It periodically reports an approximate location to your own
Supabase project and, only while you have switched the device to "lost
mode" from your dashboard, can show a message and take one webcam photo.

Only install this on devices you own or are authorized to manage.
"""

import base64
import json
import os
import sys
import time
from datetime import datetime, timezone

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")


# --------------------------------------------------------------------------- #
#  Config
# --------------------------------------------------------------------------- #
def load_config():
    if not os.path.exists(CONFIG_PATH):
        sys.exit(
            f"config.json not found. Copy config.example.json to config.json "
            f"and fill in your values.\n  expected at: {CONFIG_PATH}"
        )
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


# --------------------------------------------------------------------------- #
#  Location providers
# --------------------------------------------------------------------------- #
def locate_via_ip():
    """City-level fallback. Always available, no permission needed."""
    try:
        r = requests.get(
            "http://ip-api.com/json/?fields=status,lat,lon,query", timeout=15
        )
        d = r.json()
        if d.get("status") == "success":
            return {
                "lat": d["lat"],
                "lng": d["lon"],
                "accuracy": 5000.0,  # rough, city-level
                "source": "ip",
                "public_ip": d.get("query"),
            }
    except Exception as e:
        print(f"[ip] failed: {e}")
    return None


def locate_via_windows():
    """
    Higher accuracy (Wi-Fi based) via the Windows Location API.
    Requires 'pip install winsdk' and location access enabled in
    Windows Settings > Privacy > Location. Returns None if unavailable.
    """
    try:
        import asyncio
        from winsdk.windows.devices.geolocation import Geolocator, PositionAccuracy
    except Exception:
        return None

    async def _get():
        locator = Geolocator()
        locator.desired_accuracy = PositionAccuracy.HIGH
        pos = await locator.get_geoposition_async()
        c = pos.coordinate
        return {
            "lat": c.point.position.latitude,
            "lng": c.point.position.longitude,
            "accuracy": float(c.accuracy) if c.accuracy else None,
            "source": "wifi",
            "public_ip": None,
        }

    try:
        return asyncio.run(_get())
    except Exception as e:
        print(f"[win] location unavailable ({e}); falling back to IP")
        return None


def get_location(cfg):
    loc = None
    if cfg.get("use_windows_location"):
        loc = locate_via_windows()
    if loc is None:
        loc = locate_via_ip()
    return loc


def get_battery():
    try:
        import psutil  # optional

        b = psutil.sensors_battery()
        return int(b.percent) if b else None
    except Exception:
        return None


# --------------------------------------------------------------------------- #
#  Lost-mode actions
# --------------------------------------------------------------------------- #
def capture_photo():
    """Take a single webcam frame and return it as a base64 JPEG string."""
    try:
        import cv2
    except Exception:
        print("[photo] opencv-python not installed; skipping")
        return None
    cam = None
    try:
        cam = cv2.VideoCapture(0)
        # a few warm-up reads so the sensor adjusts exposure
        for _ in range(5):
            cam.read()
            time.sleep(0.1)
        ok, frame = cam.read()
        if not ok:
            return None
        # resize to keep it tiny (free-tier friendly)
        h, w = frame.shape[:2]
        if w > 640:
            frame = cv2.resize(frame, (640, int(h * 640 / w)))
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 50])
        if not ok:
            return None
        return base64.b64encode(buf.tobytes()).decode("ascii")
    except Exception as e:
        print(f"[photo] failed: {e}")
        return None
    finally:
        if cam is not None:
            cam.release()


def show_lost_message(message):
    """Pop a full-screen owner message. Best-effort, non-blocking."""
    if not message:
        return
    try:
        if sys.platform == "win32":
            import ctypes

            # MB_OK | MB_ICONINFORMATION | MB_TOPMOST
            ctypes.windll.user32.MessageBoxW(
                0, message, "This device is being tracked by its owner",
                0x40 | 0x40000,
            )
        else:
            print(f"[lost message] {message}")
    except Exception as e:
        print(f"[lost] message failed: {e}")


# --------------------------------------------------------------------------- #
#  Supabase RPC
# --------------------------------------------------------------------------- #
def rpc(cfg, fn, payload):
    url = f"{cfg['supabase_url']}/rest/v1/rpc/{fn}"
    headers = {
        "apikey": cfg["supabase_anon_key"],
        "Authorization": f"Bearer {cfg['supabase_anon_key']}",
        "Content-Type": "application/json",
    }
    r = requests.post(url, headers=headers, data=json.dumps(payload), timeout=30)
    r.raise_for_status()
    return r.json() if r.text else None


def report(cfg, loc):
    return rpc(
        cfg,
        "report_location",
        {
            "p_device_id": cfg["device_id"],
            "p_agent_key": cfg["agent_key"],
            "p_lat": loc.get("lat"),
            "p_lng": loc.get("lng"),
            "p_accuracy": loc.get("accuracy"),
            "p_source": loc.get("source"),
            "p_battery": get_battery(),
            "p_public_ip": loc.get("public_ip"),
        },
    )


def upload_photo(cfg, image_b64):
    rpc(
        cfg,
        "upload_photo",
        {
            "p_device_id": cfg["device_id"],
            "p_agent_key": cfg["agent_key"],
            "p_image": image_b64,
        },
    )


# --------------------------------------------------------------------------- #
#  Main loop
# --------------------------------------------------------------------------- #
def tick(cfg):
    loc = get_location(cfg)
    if not loc:
        print("[tick] no location this round")
        return
    now = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{now}] {loc['source']} {loc['lat']:.4f},{loc['lng']:.4f} "
          f"(~{loc.get('accuracy')}m)")

    state = report(cfg, loc) or {}
    if state.get("lost_mode"):
        show_lost_message(state.get("lost_message"))
        if state.get("want_photo") and cfg.get("enable_photo"):
            img = capture_photo()
            if img:
                upload_photo(cfg, img)
                print("[tick] evidence photo uploaded")


def main():
    cfg = load_config()
    interval = int(cfg.get("interval_seconds", 900))
    print(f"OpenTrack agent started. Reporting every {interval}s. Ctrl+C to stop.")
    while True:
        try:
            tick(cfg)
        except requests.HTTPError as e:
            print(f"[http] {e} — check device_id / agent_key / URL")
        except Exception as e:
            print(f"[error] {e}")
        time.sleep(interval)


if __name__ == "__main__":
    main()
