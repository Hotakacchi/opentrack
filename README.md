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
│ OpenTrack   │ ──────────────────▶ │ RPCs (validate agent_key) │ ◀──── │ dashboard  │
│ agent (exe)  │ ◀── lost/photo cmd   │ devices / locations /     │  RLS  │ map + ctrl │
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

### 2. Open the dashboard
Use the hosted copy at **https://opentrack-hotakacchi.vercel.app** (it stores nothing:
on first visit you paste *your own* Supabase URL + anon key, which are kept only
in your browser), or host your own copy of the `web/` folder on any static host
(Vercel, GitHub Pages, Cloudflare Pages, Netlify). For a self-hosted copy you can
pre-fill the values by copying `web/config.example.js` to `web/config.js`.

Then **Sign up** with an email + password and **Register device**. Click the
device to reveal its `device_id` and `agent_key`.

### 3. Install the agent on the laptop
Download the installer for your OS from the
[latest release](https://github.com/Hotakacchi/opentrack/releases/latest).
Both are tiny, native, and need no admin rights or extra runtime. Each asks for
your Supabase URL, anon key, and the dashboard's `device_id` / `agent_key`.

**Windows** (`OpenTrackSetup.exe`, ~2 MB): run it and follow the wizard. It
installs to `%LOCALAPPDATA%\OpenTrack`, starts the agent and registers it to
start at every login. Uninstall from *Settings > Apps*. Wi-Fi positioning needs
*Settings > Privacy & security > Location* on (including "Let desktop apps
access your location"); otherwise it falls back to city-level IP location.

**macOS** (`OpenTrack-mac.dmg`, universal Intel + Apple silicon, macOS 12+):
open the dmg, drag **OpenTrack** to *Applications*, then **right-click > Open**
the first time (the app is ad-hoc signed, not notarized, because notarization
needs a paid Apple developer account). A setup dialog asks for the four values;
allow Location (and Camera, used only for lost-mode photos) when prompted. It
adds itself to *Login Items*. To uninstall, remove it from *Login Items*, quit it
in Activity Monitor, delete the app and `~/Library/Application Support/OpenTrack`.

Settings live in `config.json` and a small auto-trimmed `agent.log` sits next to
it (Windows: the install folder; macOS: `~/Library/Application Support/OpenTrack`).

#### Automatic updates
Installed agents check GitHub Releases at start-up and every 6 hours. When a
newer version exists they download the installer, verify its SHA-256 against
that release's `SHA256SUMS.txt`, install it and restart; your settings are kept.
Set `"auto_update": false` in `config.json` to turn this off. (The checksum
guards against corrupted or swapped downloads, but it comes from the same
repository, so trust in updates equals trust in this repo's releases. Fork and
change `REPO` in the sources if you want to publish your own.)

#### Build from source
```bash
# Windows agent (Rust)         -> agent-rs/target/release/opentrack-agent.exe
cd agent-rs && cargo build --release
# Windows installer (Inno Setup 6)  -> installer\Output\OpenTrackSetup.exe
ISCC installer\OpenTrack.iss
# macOS app + dmg (on a Mac)   -> dist/OpenTrack-mac.dmg
sh scripts/build-mac.sh 0.2.0
```
Pushing a tag such as `v0.2.0` makes GitHub Actions build both installers and
publish a release with `SHA256SUMS.txt` (the tag must match the version in
`agent-rs/Cargo.toml`).

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
