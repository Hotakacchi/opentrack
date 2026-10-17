/* OpenTrack dashboard — talks to your own Supabase project. */
(function () {
  const cfg = window.OPENTRACK_CONFIG;
  if (!cfg || cfg.SUPABASE_URL.includes("YOUR-PROJECT")) {
    alert("Copy config.example.js to config.js and fill in your Supabase values.");
    return;
  }
  const sb = supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);

  const $ = (id) => document.getElementById(id);
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
    const { error } = await sb.auth.signInWithPassword({
      email: $("email").value.trim(), password: $("password").value,
    });
    if (error) $("authmsg").textContent = error.message;
    else refreshAuth();
  };
  $("signout").onclick = async () => { await sb.auth.signOut(); refreshAuth(); };

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
