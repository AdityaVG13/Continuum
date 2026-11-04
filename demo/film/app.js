/* Continuum 3-minute film. Picture only. Voice is recorded separately. */
(() => {
  const DURATION = 180;
  const $ = (id) => document.getElementById(id);
  const app = $("app");
  const clockEl = $("clock");
  const sceneEl = $("scene-name");
  const prompter = $("prompter");
  const tuiEl = $("tui");
  const tuiShell = $("tui-shell");
  const titles = $("titles");
  const endcard = $("endcard");
  const superEl = $("super");
  const counter = $("counter");
  const callN = $("call-n");
  const canvas = $("c");
  const params = new URLSearchParams(location.search);

  const CUES = [
    { t: 6.0,   line: "Every house has a computer nobody logs into.\nThe router." },
    { t: 14.0,  line: "Setting one up still means a sticker,\na browser tab, and a password you'll forget." },
    { t: 23.0,  line: "When it misbehaves, you reboot it and hope." },
    { t: 30.0,  line: "Continuum takes the whole thing over.\nOne command." },
    { t: 44.0,  line: "It doesn't care how you're connected.\nA cable. Your Wi-Fi. Or nothing at all." },
    { t: 53.0,  line: "I factory-reset this ASUS. The Mac has no network.\nContinuum says so, and asks for the setup network on the label." },
    { t: 64.0,  line: "It joins, finds the router,\nand names what's answering. Nothing is written yet." },
    { t: 74.0,  line: "A factory router has no password.\nContinuum mints one, locks it in the Keychain first,\nthen proves the router took it." },
    { t: 87.0,  line: "Already configured? Type its password once.\nVerified. Nothing written." },
    { t: 95.0,  line: "Then Meta. Continuum reads the models your key can use,\nwith Meta's own prices, and a ceiling on what one step can cost." },
    { t: 107.0, line: "Muse Spark 1.3. One test call proves the key." },
    { t: 115.0, line: "Spark gets named tools, not a shell.\nIt turns off the vendor services nothing here uses,\nand the router's own receipt decides if it counts." },
    { t: 128.0, line: "One reboot, approved by me.\nContinuum waits for the router to go dark and come back,\nthen proves the settings survived." },
    { t: 143.0, line: "Shaping is next: one CAKE queue on the WAN.\nThis firmware has no CAKE.\nContinuum says exactly that, and writes nothing." },
    { t: 153.0, line: "So there's no queue to measure yet,\nand no number to quote." },
    { t: 163.0, line: "Enrolled, cleaned up, rebooted and proven,\non a real router, by the router's own receipts." },
    { t: 171.0, line: "No numbers I didn't measure." },
    { t: 175.0, line: "A Meta agent that runs a real router,\nand can't run away with it." },
  ];

  const SCENES = [
    { t: 0, name: "title" },
    { t: 6, name: "house" },
    { t: 44, name: "reach" },
    { t: 74, name: "enroll" },
    { t: 95, name: "meta" },
    { t: 128, name: "proof" },
    { t: 143, name: "tune" },
    { t: 163, name: "resident" },
  ];

  const TUI = {
    noRouter: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 1 OF 8   BIND THE ROUTER</span>

Looking for your router...

Connect this Mac to the router any way you like:
  - plug a cable into one of its LAN ports, or
  - pick its Wi-Fi in the menu bar. A reset ASUS shows ASUS_XX
    (open, no password).
Continuum notices by itself; there is nothing to type here.

<span class="dim">Nothing has been written anywhere.</span>

Router  none bound   Phase  unselected   Key  missing

<span class="hd">Waiting for the router; it appears here on its own.</span>
<span class="dim">[Esc] Quit    [a] Advanced panels</span>
<span class="dim"></span><span class="hd">[BIND]</span><span class="dim">  ENROLL  KEY  SETUP  REBOOT  VERIFY  TUNE  MEASURE</span>`,

    reach: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 1 OF 8   BIND THE ROUTER</span>

Routers this Mac can reach:

<span class="hi">> 1  en0:192.168.50.1</span>   (Wi-Fi, default route)
     <span class="ok">ASUS router -- supported</span>

<span class="dim">Enter takes over the marked router. This step records the target
only; nothing is written to the router yet.</span>

Router  none bound   Phase  unselected   Key  missing

<span class="hd">[Enter] Take over this router</span>
<span class="dim">[Esc] Quit    [a] Advanced panels</span>
<span class="dim"></span><span class="hd">[BIND]</span><span class="dim">  ENROLL  KEY  SETUP  REBOOT  VERIFY  TUNE  MEASURE</span>`,

    enroll: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 2 OF 8   ENROLL THE ROUTER</span>

Creates this router's admin credential, renames its Wi-Fi and
rotates the passphrase. This host may drop off Wi-Fi and rejoin.

Factory-only: a unit that is already configured refuses safely and
nothing on it changes. On that failure you can take the unit over
with the admin password it already uses.

Router  en0:192.168.50.1   Phase  selected   Key  missing

<span class="hi">Enrolling. This can take a minute.</span>
<span class="dim">Running. q cancels; an uncertain step is never replayed.</span>

<span class="dim">[q] Cancel this step and quit</span>
<span class="dim">BIND  </span><span class="hd">[ENROLL]</span><span class="dim">  KEY  SETUP  REBOOT  VERIFY  TUNE  MEASURE</span>`,

    takeover: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 2 OF 8   ENROLL THE ROUTER</span>

Router  en0:192.168.50.1   Phase  selected   Key  missing

<span class="hd">WHY IT STOPPED</span>
  This router is already set up, so the factory ceremony refused
  and nothing on it changed.

<span class="hd">WHAT TO DO</span>
  Take it over as it is: press p and type the admin password this
  router already uses. Continuum verifies it, stores it in the OS
  vault, and continues -- nothing on the router is changed.

<span class="hd">[Enter] Retry    [p] Take over    [i] Raw output</span>
<span class="dim">BIND  </span><span class="hd">[ENROLL]</span><span class="dim">  KEY  SETUP  REBOOT  VERIFY  TUNE  MEASURE</span>`,

    picker: `<span class="hd">CONTINUUM / CHOOSE THE META MODEL</span>
<span class="dim">--------------------------------------------------------------</span>
Models this key can use (read from the provider; listing is free).
Prices: official rate card, USD per 1M tokens, checked 2026-11-04.

<span class="hi">> 1  muse-spark-1.3</span>
     in $1.250  cached $0.150  out $4.250   one setup step <= <span class="ok">$0.442</span>
     Latest Spark; tuned for tool loops. Recommended for this job.
  2  muse-wonder-1.0
     in $4.000  cached $0.200  out $20.000   one setup step <= $1.835
     Most capable; long multi-step agent work. Slowest, priciest.
  3  muse-spark-1.3-contributor
     in $0.100  cached $0.002  out $0.200   one setup step <= $0.026
     Contributor mode: Meta may train on your prompts and replies.

<span class="dim">Not offered (not tool-calling text models): muse-image-1.0, sam-3.1
Muse Spark Open is open-weight and is not served on this API.</span>

<span class="hd">[1-9] Select    [Enter] Use the marked model</span>`,

    effort: `<span class="hd">CONTINUUM / REASONING EFFORT</span>
<span class="dim">--------------------------------------------------------------</span>
Model  muse-spark-1.3

More effort = more reasoning tokens: slower and billed as output.
The output cap grows with it so reasoning cannot crowd out the answer.

  1  minimal   cap 2048 tokens/response   step <= $0.198
  2  low       cap 4096 tokens/response   step <= $0.233
  3  medium    cap 8192 tokens/response   step <= $0.303
  4  high      cap 16384 tokens/response   step <= $0.442
<span class="hi">> 5  xhigh     cap 16384 tokens/response   step <= $0.442</span>
  6  max       cap 32768 tokens/response   step <= $0.720

<span class="hd">[1-6] Select    [Enter] Save model and effort</span>`,

    setup: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 4 OF 8   SET THE ROUTER UP</span>

Meta inspects the router and applies its owned baseline: vendor
services stripped, fully reversible. No reboot, no reset and no
firmware change. The step counts only when the router's own receipt
shows the baseline applied with runtime and recovery verified.

Router  en0:192.168.50.1   Phase  enrolled   Key  <span class="ok">verified</span>

KEY        accepted by the provider (one connection-test call)

<span class="hi">Meta is working. q cancels.</span>
<span class="dim">BIND  ENROLL  KEY  </span><span class="hd">[SETUP]</span><span class="dim">  REBOOT  VERIFY  TUNE  MEASURE</span>`,

    applied: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 5 OF 8   REBOOT</span>

One reboot proves the baseline persists. The network drops for
a few minutes. This approves exactly one reboot, nothing else.

Router  en0:192.168.50.1   Phase  baseline_applied   Key  verified

RECEIPT    <span class="ok">baseline applied; runtime and recovery verified by the router</span>

META SAID
Commissioned under standing permission, no reboot.
- Applied owned baseline: disable samba, ftp, dlna, daap, webdav
- Result: phase=baseline_applied, changed_services=2,
  runtime_verified=true, recovery_verified=true
- Core routing/firewall/WiFi untouched

<span class="hd">[Enter] Reboot now (one time)</span>
<span class="dim">BIND  ENROLL  KEY  SETUP  </span><span class="hd">[REBOOT]</span><span class="dim">  VERIFY  TUNE  MEASURE</span>`,

    waiting: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 6 OF 8   WAITING FOR THE ROUTER</span>

Reboot requested. Continuum waits for the router to stop answering
and answer again (a protected read every few seconds; nothing is
written). The request's own exit code is not trusted either way.

  Went down   <span class="hi">yes</span>

Router  en0:192.168.50.1   Phase  reboot_pending   Key  verified

<span class="dim">Waiting for the router; keys are locked.</span>
<span class="dim">BIND  ENROLL  KEY  SETUP  REBOOT  </span><span class="hd">[VERIFY]</span><span class="dim">  TUNE  MEASURE</span>`,

    persist: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 7 OF 8   TUNE</span>

Shaping is one CAKE root qdisc on the WAN egress. First a read-only
preflight checks that the router has tc and reads its current root
queue. The preflight writes nothing.

PERSIST    <span class="ok">verified by the router: new boot identity, owned baseline in force</span>

<span class="hd">[Enter] Read the WAN queue (read-only)</span>
<span class="dim">BIND  ENROLL  KEY  SETUP  REBOOT  VERIFY  </span><span class="hd">[TUNE]</span><span class="dim">  MEASURE</span>`,

    tuned: `<span class="hd">CONTINUUM / SETUP</span>
<span class="dim">--------------------------------------------------------------</span>
<span class="hi">STEP 7 OF 8   TUNE</span>

Next: write ONE root qdisc and read it back from the router.

Router  en0:192.168.50.1   Phase  network_qualification_required

PREFLIGHT  tc present; eth0 root queue now: qdisc pfifo_fast 0: root

WHY IT STOPPED
  qdisc_cake_unavailable

WHAT TO DO
  This firmware's tc has no CAKE queue, so Continuum cannot shape
  here. Nothing was written; steps 1-6 stand. Press Esc to stop.

<span class="dim">[Esc] Quit    [a] Advanced panels</span>
<span class="dim">BIND  ENROLL  KEY  SETUP  REBOOT  VERIFY  </span><span class="hd">[TUNE]</span><span class="dim">  MEASURE</span>`,
  };

  const TUI_CUES = [
    { t: 50, id: "noRouter" },
    { t: 63, id: "reach" },
    { t: 74, id: "enroll" },
    { t: 87, id: "takeover" },
    { t: 95, id: "picker" },
    { t: 105, id: "effort" },
    { t: 112, id: "setup" },
    { t: 121, id: "applied" },
    { t: 130, id: "waiting" },
    { t: 139, id: "persist" },
    { t: 145, id: "tuned" },
  ];

  CUES.forEach((c) => {
    const div = document.createElement("div");
    div.className = "cue";
    div.dataset.t = String(c.t);
    div.innerHTML = `<span class="t">${fmt(c.t)}</span>${escapeHtml(c.line).replace(/\n/g, "<br>")}`;
    prompter.appendChild(div);
  });

  let time = Number(params.get("t") || 0);
  let playing = params.has("autoplay") || params.has("record");
  let last = performance.now();

  if (params.has("record")) app.classList.add("record");

  $("btn-play").addEventListener("click", toggle);
  $("btn-rec").addEventListener("click", () => {
    app.classList.toggle("record");
  });
  $("btn-restart").addEventListener("click", () => {
    time = 0;
    playing = true;
  });

  window.addEventListener("keydown", (e) => {
    if (e.code === "Space") { e.preventDefault(); toggle(); }
    if (e.key === "r" || e.key === "R") app.classList.toggle("record");
    if (e.key === "Home") { time = 0; }
    if (e.key === "ArrowRight") time = Math.min(DURATION, time + 5);
    if (e.key === "ArrowLeft") time = Math.max(0, time - 5);
    if (e.key >= "1" && e.key <= "8") time = SCENES[Number(e.key) - 1].t;
  });

  function toggle() {
    playing = !playing;
    $("btn-play").textContent = playing ? "Pause" : "Play";
  }

  /* ---------- three world ---------- */
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, preserveDrawingBuffer: params.has("render") });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 0.28;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0b0a09);
  scene.fog = new THREE.FogExp2(0x0b0a09, 0.018);

  const camera = new THREE.PerspectiveCamera(28, 16 / 9, 0.05, 80);
  const world = new THREE.Group();
  scene.add(world);

  const hemi = new THREE.HemisphereLight(0x6a736c, 0x1a1612, 0.85);
  scene.add(hemi);
  const key = new THREE.DirectionalLight(0xf0d8b8, 1.35);
  key.position.set(2.4, 4.2, 5.5);
  key.castShadow = true;
  key.shadow.mapSize.set(1024, 1024);
  key.shadow.camera.near = 0.5;
  key.shadow.camera.far = 18;
  scene.add(key);
  const windowLight = new THREE.PointLight(0xffc8a0, 0, 8, 1.4);
  windowLight.position.set(-1.05, 1.05, 0.2);
  scene.add(windowLight);
  const tableLamp = new THREE.PointLight(0xffe1c0, 1.6, 3.2, 1.6);
  tableLamp.position.set(0.2, 1.15, 0.55);
  scene.add(tableLamp);
  const rim = new THREE.PointLight(0x8fd0c8, 0, 5, 1.8);
  rim.position.set(0.55, 0.95, 0.95);
  scene.add(rim);
  const fill = new THREE.DirectionalLight(0x9eb0c4, 0.35);
  fill.position.set(-4, 3, 4);
  scene.add(fill);

  const studioMat = new THREE.MeshStandardMaterial({ color: 0x161412, roughness: 0.96, metalness: 0.02 });
  const studio = new THREE.Mesh(new THREE.CircleGeometry(22, 80), studioMat);
  studio.rotation.x = -Math.PI / 2;
  studio.receiveShadow = true;
  scene.add(studio);

  const plinth = new THREE.Mesh(
    new THREE.BoxGeometry(3.4, 0.16, 2.5),
    new THREE.MeshStandardMaterial({ color: 0x141312, roughness: 0.7, metalness: 0.08 })
  );
  plinth.position.y = 0.08;
  plinth.receiveShadow = true;
  plinth.castShadow = true;
  world.add(plinth);

  const wood = new THREE.MeshStandardMaterial({ color: 0x4a3d30, roughness: 0.82, metalness: 0.04 });
  const lineMat = new THREE.LineBasicMaterial({ color: 0xd4c6aa, transparent: true, opacity: 0.7 });

  function box(w, h, d, mat, x, y, z, parent) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
    m.position.set(x, y, z);
    m.castShadow = true;
    m.receiveShadow = true;
    (parent || world).add(m);
    return m;
  }

  function edgesOf(mesh, parent) {
    const e = new THREE.LineSegments(new THREE.EdgesGeometry(mesh.geometry), lineMat);
    e.position.copy(mesh.position);
    e.rotation.copy(mesh.rotation);
    e.scale.copy(mesh.scale);
    (parent || world).add(e);
    return e;
  }

  const floor = box(2.7, 0.03, 1.9, wood, 0, 0.175, 0);
  edgesOf(floor);
  const wallGeo = new THREE.BoxGeometry(2.7, 1.35, 1.9);
  const houseLines = new THREE.LineSegments(new THREE.EdgesGeometry(wallGeo), lineMat);
  houseLines.position.set(0, 0.86, 0);
  world.add(houseLines);
  const gable = new THREE.LineSegments(
    new THREE.BufferGeometry().setFromPoints([
      new THREE.Vector3(-1.35, 1.54, -0.95), new THREE.Vector3(0, 2.05, -0.95),
      new THREE.Vector3(0, 2.05, -0.95), new THREE.Vector3(1.35, 1.54, -0.95),
      new THREE.Vector3(-1.35, 1.54, 0.95), new THREE.Vector3(0, 2.05, 0.95),
      new THREE.Vector3(0, 2.05, 0.95), new THREE.Vector3(1.35, 1.54, 0.95),
      new THREE.Vector3(0, 2.05, -0.95), new THREE.Vector3(0, 2.05, 0.95),
    ]),
    lineMat
  );
  world.add(gable);

  const glow = new THREE.Mesh(
    new THREE.PlaneGeometry(0.55, 0.7),
    new THREE.MeshBasicMaterial({ color: 0xffc8a0, transparent: true, opacity: 0.18 })
  );
  glow.position.set(-1.305, 1.05, 0.15);
  glow.rotation.y = Math.PI / 2;
  world.add(glow);

  const table = box(1.15, 0.04, 0.58, wood, 0.15, 0.42, 0.18);
  const tableLeg = (x, z) => box(0.04, 0.22, 0.04, wood, x, 0.29, z);
  tableLeg(-0.32, 0.0);
  tableLeg(0.58, 0.0);
  tableLeg(-0.32, 0.38);
  tableLeg(0.58, 0.38);

  const metal = new THREE.MeshPhysicalMaterial({
    color: 0x2c3036, metalness: 0.68, roughness: 0.34, clearcoat: 0.4, clearcoatRoughness: 0.35,
  });
  const router = new THREE.Group();
  router.position.set(0.28, 0.485, 0.12);
  world.add(router);
  const body = new THREE.Mesh(new THREE.BoxGeometry(0.34, 0.05, 0.18), metal);
  body.castShadow = true;
  router.add(body);
  const bevel = new THREE.Mesh(new THREE.BoxGeometry(0.28, 0.012, 0.14), metal);
  bevel.position.y = 0.026;
  router.add(bevel);
  for (const [x, z] of [[-0.12, -0.06], [0.12, -0.06], [-0.12, 0.05], [0.12, 0.05]]) {
    const ant = new THREE.Mesh(
      new THREE.CylinderGeometry(0.006, 0.008, 0.22, 8),
      new THREE.MeshStandardMaterial({ color: 0x111214, roughness: 0.4, metalness: 0.6 })
    );
    ant.position.set(x, 0.14, z);
    ant.rotation.z = x < 0 ? 0.12 : -0.12;
    router.add(ant);
  }
  const led = new THREE.Mesh(
    new THREE.BoxGeometry(0.16, 0.004, 0.006),
    new THREE.MeshBasicMaterial({ color: 0xc9a227 })
  );
  led.position.set(0, 0.01, 0.082);
  router.add(led);

  const pips = [];
  const pipNames = ["samba", "ftp", "dlna", "daap", "webdav"];
  pipNames.forEach((name, i) => {
    const pip = new THREE.Mesh(
      new THREE.BoxGeometry(0.018, 0.006, 0.006),
      new THREE.MeshBasicMaterial({ color: 0x8fd0a8 })
    );
    pip.position.set(-0.08 + i * 0.04, 0.026, 0.07);
    pip.userData.name = name;
    router.add(pip);
    pips.push(pip);
  });

  const laptop = new THREE.Group();
  laptop.position.set(-0.42, 0.46, 0.16);
  world.add(laptop);
  const base = new THREE.Mesh(
    new THREE.BoxGeometry(0.32, 0.012, 0.22),
    new THREE.MeshStandardMaterial({ color: 0xc5c0b8, metalness: 0.7, roughness: 0.25 })
  );
  laptop.add(base);
  const lid = new THREE.Mesh(
    new THREE.BoxGeometry(0.32, 0.20, 0.008),
    new THREE.MeshStandardMaterial({ color: 0xbdb8b0, metalness: 0.7, roughness: 0.25 })
  );
  lid.position.set(0, 0.10, -0.11);
  lid.rotation.x = -0.18;
  laptop.add(lid);
  const screen = new THREE.Mesh(
    new THREE.PlaneGeometry(0.28, 0.16),
    new THREE.MeshBasicMaterial({ color: 0x7ec9d4, transparent: true, opacity: 0.35 })
  );
  screen.position.set(0, 0.10, -0.104);
  screen.rotation.x = -0.18;
  laptop.add(screen);

  const vault = new THREE.Group();
  vault.position.set(0.62, 0.455, 0.28);
  world.add(vault);
  const vaultBody = new THREE.Mesh(
    new THREE.BoxGeometry(0.09, 0.07, 0.07),
    new THREE.MeshStandardMaterial({ color: 0x3a342c, metalness: 0.5, roughness: 0.4 })
  );
  vault.add(vaultBody);
  const vaultLid = new THREE.Mesh(
    new THREE.BoxGeometry(0.09, 0.01, 0.07),
    new THREE.MeshStandardMaterial({ color: 0x4a433a, metalness: 0.55, roughness: 0.35 })
  );
  vaultLid.position.y = 0.04;
  vault.add(vaultLid);
  const keySpark = new THREE.Mesh(
    new THREE.SphereGeometry(0.012, 12, 12),
    new THREE.MeshBasicMaterial({ color: 0xe8c36a })
  );
  keySpark.position.set(0.62, 0.50, 0.28);
  keySpark.visible = false;
  world.add(keySpark);

  const wanCurve = new THREE.CatmullRomCurve3([
    new THREE.Vector3(0.44, 0.49, 0.12),
    new THREE.Vector3(1.15, 0.52, 0.35),
    new THREE.Vector3(2.3, 0.85, 0.9),
    new THREE.Vector3(4.4, 1.5, 1.15),
    new THREE.Vector3(6.8, 2.1, 0.2),
  ]);
  const cable = new THREE.Mesh(
    new THREE.TubeGeometry(wanCurve, 80, 0.012, 8, false),
    new THREE.MeshStandardMaterial({ color: 0x2a2926, roughness: 0.55, metalness: 0.15 })
  );
  world.add(cable);

  const isp = new THREE.LineSegments(
    new THREE.EdgesGeometry(new THREE.BoxGeometry(0.8, 0.8, 0.8)),
    new THREE.LineBasicMaterial({ color: 0x6a6458, transparent: true, opacity: 0.35 })
  );
  isp.position.set(6.8, 2.1, 0.2);
  world.add(isp);

  const N = 70;
  const packetGeo = new THREE.BoxGeometry(0.035, 0.016, 0.048);
  const packetMat = new THREE.MeshBasicMaterial({ color: 0xe8dfcc, transparent: true, opacity: 0.9 });
  const packets = new THREE.InstancedMesh(packetGeo, packetMat, N);
  world.add(packets);
  const prog = new Float32Array(N);
  for (let i = 0; i < N; i++) prog[i] = i / N;
  const dummy = new THREE.Object3D();
  const pnt = new THREE.Vector3();

  const cageMat = new THREE.LineBasicMaterial({ color: 0x8fd0c8, transparent: true, opacity: 0 });
  const cage = new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.BoxGeometry(0.55, 0.42, 0.42)), cageMat);
  cage.position.set(0.28, 0.62, 0.12);
  cage.scale.setScalar(0.15);
  world.add(cage);

  const ports = [];
  function makePort(label, x, color) {
    const g = new THREE.Group();
    const cube = new THREE.Mesh(
      new THREE.BoxGeometry(0.07, 0.05, 0.03),
      new THREE.MeshStandardMaterial({ color, metalness: 0.4, roughness: 0.45 })
    );
    g.add(cube);
    g.position.set(x, 0.72, 0.34);
    g.visible = false;
    world.add(g);
    ports.push(g);
    return g;
  }
  const portInspect = makePort("inspect", -0.08, 0x2a3330);
  const portApply = makePort("apply", 0.16, 0x2a3330);
  const portRestore = makePort("restore", 0.40, 0x2a3330);
  const portReboot = makePort("reboot", 0.64, 0x3a2222);
  const cap = new THREE.Mesh(
    new THREE.BoxGeometry(0.078, 0.012, 0.04),
    new THREE.MeshStandardMaterial({ color: 0x8a3a3a, metalness: 0.5, roughness: 0.35 })
  );
  cap.position.y = 0.032;
  portReboot.add(cap);

  const receipt = new THREE.Mesh(
    new THREE.PlaneGeometry(0.36, 0.22),
    new THREE.MeshBasicMaterial({ map: receiptTexture("idle"), transparent: true, opacity: 0 })
  );
  receipt.position.set(0.28, 0.72, 0.36);
  world.add(receipt);

  const SHOTS = [
    { t: 0,   p: [0.62, 0.78, 1.55], l: [0.28, 0.52, 0.12], fov: 28, exp: 0.35 },
    { t: 6,   p: [2.15, 1.55, 3.85], l: [0.10, 0.70, 0.10], fov: 32, exp: 1.08 },
    { t: 16,  p: [1.15, 1.05, 2.35], l: [0.22, 0.52, 0.14], fov: 30, exp: 1.12 },
    { t: 30,  p: [0.72, 0.86, 1.72], l: [0.28, 0.52, 0.12], fov: 28, exp: 1.10 },
    { t: 44,  p: [0.40, 0.95, 1.95], l: [-0.10, 0.52, 0.12], fov: 30, exp: 1.08 },
    { t: 64,  p: [0.78, 0.90, 1.82], l: [0.20, 0.52, 0.12], fov: 29, exp: 1.08 },
    { t: 74,  p: [0.92, 0.92, 1.78], l: [0.38, 0.52, 0.18], fov: 30, exp: 1.10 },
    { t: 95,  p: [0.55, 0.95, 1.85], l: [0.05, 0.55, 0.12], fov: 30, exp: 1.10 },
    { t: 115, p: [1.05, 1.05, 2.05], l: [0.28, 0.58, 0.12], fov: 32, exp: 1.12 },
    { t: 128, p: [0.85, 0.92, 1.78], l: [0.28, 0.54, 0.12], fov: 29, exp: 1.05 },
    { t: 143, p: [1.60, 1.20, 2.80], l: [0.80, 0.60, 0.30], fov: 30, exp: 1.10 },
    { t: 163, p: [2.35, 1.65, 4.05], l: [0.05, 0.70, 0.10], fov: 32, exp: 1.00 },
    { t: 176, p: [0.70, 0.82, 1.55], l: [0.28, 0.52, 0.12], fov: 26, exp: 0.42 },
  ];

  function lerp(a, b, t) { return a + (b - a) * t; }
  function clamp(x, a, b) { return Math.min(b, Math.max(a, x)); }
  function smoother(e0, e1, x) {
    const t = clamp((x - e0) / Math.max(0.0001, e1 - e0), 0, 1);
    return t * t * t * (t * (t * 6 - 15) + 10);
  }
  function mix3(out, a, b, t) {
    out.set(lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t));
  }

  const camPos = new THREE.Vector3();
  const camLook = new THREE.Vector3();

  function placeCamera(t) {
    let i = 0;
    while (i < SHOTS.length - 1 && SHOTS[i + 1].t <= t) i += 1;
    const a = SHOTS[i];
    const b = SHOTS[Math.min(i + 1, SHOTS.length - 1)];
    const u = b === a ? 1 : smoother(a.t, b.t, t);
    mix3(camPos, a.p, b.p, u);
    mix3(camLook, a.l, b.l, u);
    // While the terminal occupies the right half, pan the set into the left
    // half so the router and laptop stay visible beside it.
    const pan = 0.36 * smoother(46, 50, t) * (1 - smoother(175, 177, t));
    camPos.x += pan; camLook.x += pan;
    camera.position.copy(camPos);
    camera.lookAt(camLook);
    camera.fov = lerp(a.fov, b.fov, u);
    camera.updateProjectionMatrix();
    renderer.toneMappingExposure = lerp(a.exp, b.exp, u);
  }

  let congestion = 0;
  let lastTui = "";
  let lastCue = -1;
  let rebootPulse = 0;

  function sync(t) {
    placeCamera(t);

    const houseOn = smoother(4.5, 9, t);
    windowLight.intensity = 3.2 * houseOn;
    glow.material.opacity = 0.12 + 0.16 * houseOn;

    congestion = 0;
    if (t >= 14 && t < 44) congestion = smoother(14, 22, t) * (1 - smoother(38, 44, t));
    else congestion = 0.12;

    const cageOn = smoother(115, 124, t);
    cage.scale.setScalar(0.15 + 0.85 * cageOn);
    cageMat.opacity = 0.85 * cageOn;
    ports.forEach((p) => { p.visible = cageOn > 0.35; p.scale.setScalar(clamp(cageOn * 1.2, 0, 1)); });
    rim.intensity = 1.4 * cageOn;

    const enroll = t >= 74 && t < 95;
    vaultLid.rotation.x = enroll ? -1.15 * smoother(74, 79, t) : 0;
    if (t >= 78 && t < 86) {
      keySpark.visible = true;
      const u = smoother(78, 85, t);
      keySpark.position.lerpVectors(
        new THREE.Vector3(0.62, 0.52, 0.28),
        new THREE.Vector3(0.28, 0.52, 0.12),
        u
      );
    } else {
      keySpark.visible = false;
    }

    const enrolled = t >= 86;
    const dark = t >= 132 && t < 137.5;
    led.material.color.set(dark ? 0x050505 : enrolled ? 0x8fd0c8 : (t % 1.2 < 0.6 ? 0xc9a227 : 0x3a3010));

    pips.forEach((pip, i) => pip.material.color.set(dark ? 0x050505 : (t >= 121 && i !== 1) ? 0x3a2222 : 0x8fd0a8));

    if (t >= 128 && t < 132) {
      rebootPulse = Math.sin((t - 128) * 18) * 0.012;
      portReboot.position.x = 0.64 + rebootPulse;
      cap.material.color.set(0xc96b6b);
    } else {
      portReboot.position.x = 0.64;
      cap.material.color.set(0x8a3a3a);
    }

    receipt.visible = false;

    screen.material.opacity = t < 28 ? 0.15 + 0.25 * (0.5 + 0.5 * Math.sin(t * 6)) : (t < 44 ? 0.12 : 0.28);
    screen.material.color.set(t < 44 && t > 20 ? 0xc9a227 : 0x7ec9d4);

    counter.classList.toggle("show", false);
    callN.textContent = "0";

    titles.classList.toggle("show", t < 5.6 || (t >= 36.5 && t < 43.5));
    endcard.classList.toggle("show", t >= 176.2);

    let tuiId = null;
    for (const cue of TUI_CUES) if (t >= cue.t) tuiId = cue.id;
    if (t >= 176) tuiId = null;
    tuiShell.classList.toggle("show", Boolean(tuiId));
    if (tuiId && tuiId !== lastTui) {
      tuiEl.innerHTML = TUI[tuiId];
      lastTui = tuiId;
    }

    let cueIdx = -1;
    for (let i = 0; i < CUES.length; i++) if (t >= CUES[i].t) cueIdx = i;
    if (cueIdx !== lastCue) {
      lastCue = cueIdx;
      const nodes = prompter.querySelectorAll(".cue");
      nodes.forEach((n, i) => {
        n.classList.toggle("now", i === cueIdx);
        n.classList.toggle("next", i === cueIdx + 1);
      });
      if (cueIdx >= 0) {
        nodes[cueIdx].scrollIntoView({ block: "center", behavior: "smooth" });
        superEl.innerHTML = escapeHtml(CUES[cueIdx].line).replace(/\n/g, "<br>");
      }
    }
    superEl.classList.toggle("show", cueIdx >= 0 && t < 176 && !app.classList.contains("record"));

    let sceneName = SCENES[0].name;
    for (const s of SCENES) if (t >= s.t) sceneName = s.name;
    sceneEl.textContent = sceneName;
    clockEl.textContent = fmt(t);
    $("btn-play").textContent = playing ? "Pause" : "Play";
  }

  function tickPackets(dt, t) {
    for (let i = 0; i < N; i++) {
      let speed = 0.07 + (i % 7) * 0.008;
      if (congestion > 0.2 && prog[i] < 0.22) speed *= 1 - congestion * 0.9;
      if (t < 8) speed *= 0.15;
      prog[i] += dt * speed;
      if (prog[i] > 1) prog[i] -= 1;
      const u = Math.min(0.999, Math.max(0, prog[i] % 1));
      wanCurve.getPoint(u, pnt);
      if (!Number.isFinite(pnt.x)) continue;
      dummy.position.copy(pnt);
      dummy.rotation.set(0, prog[i] * 6, 0);
      const s = 0.7 + 0.5 * (1 - congestion * (prog[i] < 0.22 ? 1 : 0));
      dummy.scale.setScalar(s);
      dummy.updateMatrix();
      packets.setMatrixAt(i, dummy.matrix);
    }
    packets.instanceMatrix.needsUpdate = true;
    packetMat.opacity = t < 8 ? 0.15 : 0.9;
  }

  function resize() {
    const stage = $("stage");
    const w = stage.clientWidth;
    const h = stage.clientHeight;
    camera.aspect = w / Math.max(1, h);
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
  }
  window.addEventListener("resize", resize);
  resize();

  // Deterministic frame stepping for offline rendering (demo/film/render.mjs):
  // ?render=1 stops the clock; window.__frame(t, dt) draws exactly time t.
  const rendering = params.has("render");
  if (rendering) {
    playing = false;
    app.classList.add("record", "render");
    window.__frame = (t, dt) => {
      time = t;
      sync(time);
      tickPackets(dt, time);
      renderer.render(scene, camera);
      return true;
    };
  }
  function loop(now) {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    if (playing) {
      time += dt;
      if (time >= DURATION) { time = DURATION; playing = false; }
    }
    try {
      sync(time);
      tickPackets(dt, time);
      renderer.render(scene, camera);
    } catch (err) {
      console.error("film frame", time.toFixed(2), err);
    }
    if (!rendering) requestAnimationFrame(loop);
  }
  window.addEventListener("error", (e) => console.error("film error", e.message, e.lineno));
  requestAnimationFrame(loop);
  if (playing) $("btn-play").textContent = "Pause";

  function labelTexture(text) {
    const c = document.createElement("canvas");
    c.width = 256; c.height = 64;
    const ctx = c.getContext("2d");
    ctx.clearRect(0, 0, 256, 64);
    ctx.fillStyle = "rgba(8,8,7,0.0)";
    ctx.fillRect(0, 0, 256, 64);
    ctx.font = "500 28px 'IBM Plex Mono', monospace";
    ctx.fillStyle = "#e8dfcc";
    ctx.textAlign = "center";
    ctx.fillText(text, 128, 40);
    const tex = new THREE.CanvasTexture(c);
    tex.colorSpace = THREE.SRGBColorSpace;
    return tex;
  }

  function receiptTexture(kind) {
    const c = document.createElement("canvas");
    c.width = 512; c.height = 320;
    const ctx = c.getContext("2d");
    ctx.fillStyle = "#e8dfcc";
    ctx.fillRect(0, 0, 512, 320);
    ctx.fillStyle = "#1a1814";
    ctx.font = "500 22px 'IBM Plex Mono', monospace";
    ctx.fillText("RECEIPT", 28, 48);
    ctx.font = "400 18px 'IBM Plex Mono', monospace";
    const lines = kind === "print"
      ? ["apply            samba off", "ftp              kept", "readback         verified", "reboot           refused", "half-state       none"]
      : ["waiting"];
    lines.forEach((ln, i) => ctx.fillText(ln, 28, 100 + i * 36));
    const tex = new THREE.CanvasTexture(c);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.userData.kind = kind;
    return tex;
  }

  function fmt(t) {
    const m = Math.floor(t / 60);
    const s = t - m * 60;
    return `${String(m).padStart(2, "0")}:${s.toFixed(1).padStart(4, "0")}`;
  }
  function escapeHtml(s) {
    return s.replace(/[&<>]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[ch]));
  }
})();
