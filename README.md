# OpenTrack — self-hosted laptop finder

Open-source anti-theft tracker for **laptops you own**. A small agent on your
laptop reports its approximate location to **your own free Supabase project**;
a web dashboard shows it on a map. If the laptop goes missing you can flip it
into *lost mode* to show a message and take one webcam photo.

Everything runs entirely on free tiers: **Supabase free** (database + auth) and
any static host (**GitHub Pages / Cloudflare Pages / Netlify free**) for the
dashboard. No server to pay for.

> ⚠️ **Only install this on devices you own or are authorized to manage.**
> Secretly tracking someone else's device or recording a person without a
> lawful basis is illegal in most places. Lost mode shows a visible on-screen
> notice by design.

---

## How it works

```
 your laptop                         Supabase (your free project)        your browser
┌─────────────┐   report_location   ┌──────────────────────────┐       ┌────────────┐
│ tracker     │ ──────────────────▶ │ RPCs (validate agent_key) │ ◀──── │ dashboard  │
│ agent (py)  │ ◀── lost/photo cmd   │ devices / locations /     │  RLS  │ map + ctrl │
│             │ ── upload_photo ───▶ │ photos  (row-level secure) │       │            │
└─────────────┘                      └──────────────────────────┘       └────────────┘
```

- The agent talks only to **RPC functions** using your project's public *anon*
  key plus a per-device `agent_key`. Row Level Security means each account sees
  only its own devices — so anyone can register on a shared deployment safely.
- Location comes from the **Windows Location API** (Wi-Fi based, ~tens of m)
  when available, otherwise an **IP lookup** (city level). No GPS needed.

---

## Setup (about 10 minutes)

### 1. Create your Supabase project (free)
1. Sign up at <https://supabase.com> and create a new project.
2. Open **SQL Editor**, paste the contents of [`supabase/schema.sql`](supabase/schema.sql), and run it.
3. In **Project Settings → API**, copy your **Project URL** and **anon public** key.

### 2. Deploy the dashboard (free static hosting)
1. Copy `web/config.example.js` to `web/config.js` and paste your URL + anon key.
2. Serve the `web/` folder. Locally: `python -m http.server -d web 8000`.
   To publish: push `web/` to GitHub Pages, Cloudflare Pages, or Netlify.
3. Open it, **Sign up** with an email + password, then **Register device**.
   Click the device to reveal its `device_id` and `agent_key`.

### 3. Install the agent on the laptop
```bash
cd agent
pip install -r requirements.txt           # requests; opencv-python for photos
copy config.example.json config.json      # (cp on macOS/Linux)
```
Fill `config.json` with your Supabase URL, anon key, and the device's
`device_id` / `agent_key`. Then run:
```bash
python tracker_agent.py
```
To start it automatically at login on Windows, create a Task Scheduler task
(trigger: *At log on*, action: `pythonw tracker_agent.py`).

---

## Using lost mode
From the dashboard, select the device and **Enable lost mode** (optionally with
a message), or **Request a photo**. On its next check-in the agent shows the
message and, if asked, uploads one webcam photo that appears under the device.

Tighten the `interval_seconds` (default 900 = 15 min) only if you lose the
laptop — a short interval is fine for a day or two and still well within the
free tier.

## Staying inside the free tier
- Location rows are tiny and auto-pruned after 90 days.
- Photos are downscaled to 640px JPEG (~30–60 KB) and capped at the newest 20
  per device, so storage stays far under Supabase's 500 MB.

## License
MIT — see [LICENSE](LICENSE).
