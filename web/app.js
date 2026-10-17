/* OpenTrack dashboard — talks to your own Supabase project. */
(function () {
  const $ = (id) => document.getElementById(id);

  // Config comes from config.js (self-hosted) or, on a shared deployment,
  // from the visitor's own Supabase project saved in this browser.
  function loadCfg() {
    const c = window.OPENTRACK_CONFIG;
    if (c && c.SUPABASE_URL && !c.SUPABASE_URL.includes("YOUR-PROJECT")) return c;
    try {
      const s = JSON.parse(localStorage.getItem("opentrack_cfg") || "null");
      if (s && s.SUPABASE_URL && s.SUPABASE_ANON_KEY) return s;
    } catch (_) {}
    return null;
  }
  const cfg = loadCfg();
  if (!cfg) {
    $("setup").classList.remove("hidden");
    $("auth").classList.add("hidden");
    $("saveCfg").onclick = () => {
      const url = $("cfgUrl").value.trim().replace(/\/+$/, "");
      const key = $("cfgKey").value.trim();
      if (!/^https:\/\/.+/.test(url) || !key) {
        $("cfgmsg").textContent = "Enter your https:// project URL and the anon key.";
        return;
      }
      try {
        localStorage.setItem("opentrack_cfg",
          JSON.stringify({ SUPABASE_URL: url, SUPABASE_ANON_KEY: key }));
      } catch (_) {
        $("cfgmsg").textContent = "Could not save to this browser (storage blocked).";
        return;
      }
      location.reload();
    };
    return;
  }
  // Keep the login on this device: the session (access + refresh token) is
  // stored in localStorage and refreshed automatically, so you stay signed in
  // across reloads and browser restarts until you press Sign out. The password
  // itself is never stored. If storage is blocked we fall back to memory.
  const memory = {};
  const storage = {
    getItem: (k) => { try { return localStorage.getItem(k); } catch (_) { return memory[k] ?? null; } },
    setItem: (k, v) => { try { localStorage.setItem(k, v); } catch (_) { memory[k] = v; } },
    removeItem: (k) => { try { localStorage.removeItem(k); } catch (_) { delete memory[k]; } },
  };
  const sb = supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storageKey: "opentrack_session",
      storage,
    },
  });
  let devices = [];
  let selected = null;
  let map, trackLayer, marker;

  // ---- map ----------------------------------------------------------------
  function initMap() {
    if (map) return;
    map = L.map("map").setView([20, 0], 2);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: "&copy; OpenStreetMap",
    }).addTo(map);
    trackLayer = L.layerGroup().addTo(map);
  }

  async function drawHistory(deviceId) {
    initMap();
    trackLayer.clearLayers();
    const { data, error } = await sb
      .from("locations")
      .select("lat,lng,accuracy,source,ts")
      .eq("device_id", deviceId)
      .order("ts", { ascending: false })
      .limit(200);
    if (error) return console.error(error);
    const pts = (data || []).filter((p) => p.lat != null).reverse();
    if (!pts.length) return;
    const latlngs = pts.map((p) => [p.lat, p.lng]);
    L.polyline(latlngs, { color: "#4f8cff", weight: 2, opacity: 0.6 }).addTo(trackLayer);
    const last = pts[pts.length - 1];
    L.circle([last.lat, last.lng], {
      radius: last.accuracy || 300, color: "#4f8cff", fillOpacity: 0.1,
    }).addTo(trackLayer);
    L.marker([last.lat, last.lng]).addTo(trackLayer)
      .bindPopup(`${last.source} · ${new Date(last.ts).toLocaleString()}`)
      .openPopup();
    map.setView([last.lat, last.lng], 15);
  }

  // ---- auth ---------------------------------------------------------------
  async function refreshAuth() {
    const { data } = await sb.auth.getSession();
    const signedIn = !!data.session;
    $("auth").classList.toggle("hidden", signedIn);
    $("devicePanel").classList.toggle("hidden", !signedIn);
    if (signedIn) loadDevices();
    else { $("controls").classList.add("hidden"); }
  }

  $("signup").onclick = async () => {
    const { error } = await sb.auth.signUp({
      email: $("email").value.trim(), password: $("password").value,
    });
    $("authmsg").textContent = error ? error.message
      : "Check your email to confirm, then sign in.";
  };
  $("signin").onclick = async () => {
    const email = $("email").value.trim();
    const { error } = await sb.auth.signInWithPassword({
      email, password: $("password").value,
    });
    if (error) { $("authmsg").textContent = error.message; return; }
    try { localStorage.setItem("opentrack_email", email); } catch (_) {}
    $("password").value = "";   // never keep the password around
    $("authmsg").textContent = "";
    refreshAuth();
  };
  $("signout").onclick = async () => { await sb.auth.signOut(); refreshAuth(); };

  // Pre-fill the last email used on this device.
  try { $("email").value = localStorage.getItem("opentrack_email") || ""; } catch (_) {}

  // Signed out elsewhere (another tab) or the refresh token expired/revoked.
  sb.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT") {
      selected = null;
      devices = [];
      refreshAuth();
    }
  });
  $("resetCfg").onclick = async () => {
    if (!confirm("Forget this Supabase project in this browser?")) return;
    await sb.auth.signOut();
    try { localStorage.removeItem("opentrack_cfg"); } catch (_) {}
    location.reload();
  };

  // ---- devices ------------------------------------------------------------
  async function loadDevices() {
    const { data, error } = await sb
      .from("devices")
      .select("*")
      .order("created_at", { ascending: true });
    if (error) return console.error(error);
    devices = data || [];
    renderDevices();
  }

  function renderDevices() {
    const box = $("devices");
    box.innerHTML = "";
    devices.forEach((d) => {
      const el = document.createElement("div");
      el.className = "device" + (selected && selected.id === d.id ? " active" : "");
      const seen = d.last_seen ? new Date(d.last_seen).toLocaleString() : "never";
      el.innerHTML =
        `<div class="nm">${escapeHtml(d.name)} ` +
        `${d.lost_mode ? '<span class="badge lost">LOST</span>' : ""}</div>` +
        `<div class="mt">last seen: ${seen}</div>`;
      el.onclick = () => selectDevice(d);
      box.appendChild(el);
    });
  }

  $("addDevice").onclick = async () => {
    const name = $("newDeviceName").value.trim();
    if (!name) return;
    const { data: u } = await sb.auth.getUser();
    const { error } = await sb.from("devices").insert({ name, owner: u.user.id });
    if (error) return alert(error.message);
    $("newDeviceName").value = "";
    loadDevices();
  };

  function selectDevice(d) {
    selected = d;
    renderDevices();
    $("controls").classList.remove("hidden");
    $("selName").textContent = d.name;
    $("enroll").innerHTML =
      `Put these in the agent's <code>config.json</code>:<br>` +
      `device_id: <code>${d.id}</code><br>` +
      `agent_key: <code>${d.agent_key}</code>`;
    $("lostMsg").value = d.lost_message || "";
    $("toggleLost").textContent = d.lost_mode ? "Disable lost mode" : "Enable lost mode";
    drawHistory(d.id);
    loadPhotos(d.id);
  }

  $("toggleLost").onclick = async () => {
    if (!selected) return;
    const next = !selected.lost_mode;
    const { error } = await sb.from("devices")
      .update({ lost_mode: next, lost_message: $("lostMsg").value })
      .eq("id", selected.id);
    if (error) return alert(error.message);
    selected.lost_mode = next;
    await loadDevices();
    selectDevice(devices.find((x) => x.id === selected.id));
  };

  $("reqPhoto").onclick = async () => {
    if (!selected) return;
    const { error } = await sb.from("devices")
      .update({ want_photo: true, lost_mode: true, lost_message: $("lostMsg").value })
      .eq("id", selected.id);
    if (error) return alert(error.message);
    alert("Photo requested. It will appear after the device's next check-in.");
  };

  async function loadPhotos(deviceId) {
    const box = $("photos");
    box.innerHTML = "";
    const { data } = await sb
      .from("photos").select("image,ts")
      .eq("device_id", deviceId).order("ts", { ascending: false }).limit(5);
    (data || []).forEach((p) => {
      const img = document.createElement("img");
      img.src = "data:image/jpeg;base64," + p.image;
      img.title = new Date(p.ts).toLocaleString();
      box.appendChild(img);
    });
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  initMap();
  refreshAuth();
  // light auto-refresh of the selected device
  setInterval(() => { if (selected) { loadDevices(); } }, 30000);
})();
