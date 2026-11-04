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
    { t: 8.0,  line: "There's a computer in my house I never log into." },
    { t: 14.0, line: "That's the router.\nAgents treat it like weather." },
    { t: 22.0, line: "They wait out the queue.\nOr they take a shell and hope." },
    { t: 30.0, line: "I didn't want a shell.\nI wanted a cage." },
    { t: 38.0, line: "This is Continuum." },
    { t: 46.0, line: "Factory-reset an ASUS GT-AX11000\nand there is no admin password.\nNothing to type." },
    { t: 56.0, line: "The box is waiting for someone to invent one." },
    { t: 64.0, line: "Continuum invents it.\nLocks it in the Mac keychain first.\nThen proves the router accepted it." },
    { t: 76.0, line: "After that the factory default is dead.\nA retry looks.\nIt does not run the ceremony twice." },
    { t: 86.0, line: "The password never reaches the model." },
    { t: 94.0, line: "Then I write the list.\nWhat Meta is allowed to touch." },
    { t: 102.0, line: "It can read the list.\nIt cannot add to it." },
    { t: 110.0, line: "Reboot stays off unless I say so\nwith a separate key." },
    { t: 120.0, line: "muse-wonder-1.0 does not get a shell.\nIt gets tools with names.\nmanage_device. apply_qos." },
    { t: 132.0, line: "I said keep FTP.\nIt has to." },
    { t: 138.0, line: "A sentence in the chat cannot mint a reboot." },
    { t: 146.0, line: "Every write is a transaction.\nPicture of before. Change. Independent read." },
    { t: 156.0, line: "If the box can't do it, we refuse.\nWe do not leave it half-set." },
    { t: 166.0, line: "Then it goes quiet.\nA healthy night costs zero Muse calls." },
    { t: 174.0, line: "I'm not quoting a number I didn't measure." },
    { t: 178.0, line: "A Meta agent that can operate a real router —\nand cannot run away with it." },
  ];

  const SCENES = [
    { t: 0, name: "title" },
    { t: 8, name: "house" },
    { t: 30, name: "cage-wanted" },
    { t: 46, name: "factory" },
    { t: 64, name: "enroll" },
    { t: 94, name: "policy" },
    { t: 120, name: "meta" },
    { t: 166, name: "quiet" },
  ];

  const TUI = {
    deviceFactory: `<span class="hd">CONTINUUM - DEVICE              META NOT CONFIGURED</span>
 <span class="dim">1 Overview  2 Network  [3] Device  4 Programs  5 Resident</span>
<span class="dim">WATCHING just now | SELECTED en0:192.168.50.1 factory-pending
PERMISSION none | RESIDENT not running</span>

DEVICE / LIFECYCLE

Selected    en0:192.168.50.1:80
Identity    GT-AX11000 / <span class="redact">mac</span> / 3.0.0.4/388/23285
Phase       <span class="hi">factory-pending</span>
SETUP       [ ] not granted
RUNTIME     [ ] not verified
RECOVERY    [ ] not verified
PERSIST     [ ] not verified
READY       false

<span class="dim">A factory unit has no admin password to type.</span>
<span class="hd">[n] Enroll: create the admin credential on a factory unit</span>`,

    enrollRun: `<span class="hd">CONTINUUM - RESULT                         ENROLL</span>
<span class="dim">execute granted · vault first · then the vendor form</span>

  credential   <span class="hi">minted</span>
  staging      macOS keychain  <span class="ok">before first write</span>
  qis          submitting vendor first-run
  protected    waiting on readback
  factory      admin/admin still live until prove

<span class="dim">The model is not in this path.
A provider outage cannot leave the box with no way in.</span>`,

    enrollOk: `<span class="hd">CONTINUUM - RESULT                         ENROLL</span>
<span class="ok">verified</span>

  credential   staged (keychain)  never in transcript
  qis          submitted
  protected    read  <span class="ok">verified</span>
  factory      default <span class="bad">dead</span>
  retry        inspect — ceremony not replayed
  model        <span class="dim">did not receive the secret</span>

<span class="dim">Identity  GT-AX11000 / firmware 3.0.0.4
Phase     enrolled</span>`,

    policy: `<span class="hd">CONTINUUM - PERMISSIONS              OWNER POLICY</span>
<span class="dim">Meta may read this. Meta cannot widen it.</span>

  inspect          allow
  enroll           allow
  runtime          allow
  apply            allow
  restore          allow
  apply_qos        allow
  restore_qos      allow
  <span class="bad">reboot            deny</span>

  protected        FTP  (must remain)
  local programs   opt-in, sandboxed
  reboot           separate key  [b]

<span class="dim">A model message is not authority.</span>`,

    talk: `<span class="hd">CONTINUUM - TALK                   muse-wonder-1.0</span>
<span class="dim">owner · 1 / 4 calls this session · 2048 output cap</span>

<span class="hi">Keep FTP enabled. Inspect and say what you would
change. Do not reboot.</span>

<span class="dim">tool   manage_device
op     inspect
cred   not in context</span>`,

    tool: `<span class="hd">CONTINUUM - RESULT                    manage_device</span>
<span class="dim">operation  apply · candidate  en0:192.168.50.1</span>

  samba     on  →  <span class="hi">off</span>
  ftp       on  →  <span class="ok">on</span>   (protected)
  dlna      on  →  on
  daap      on  →  on
  webdav    on  →  on

  reboot    <span class="bad">refused</span>  owner policy
  shell     never issued
  password  never sent`,

    receipt: `<span class="hd">CONTINUUM - RECEIPT                         APPLY</span>

  before-image     captured
  change           samba disabled
  independent read <span class="ok">verified</span>
  restore          available  [r]

<span class="hd">CONTINUUM - RESULT                         read_qos</span>
  root             vendor-managed
  <span class="bad">refused          qdisc_root_already_managed</span>
  half-state       none

<span class="dim">A model's claim of success is not evidence.
The readback is.</span>`,

    resident: `<span class="hd">CONTINUUM - RESIDENT                         LIVE</span>

STATE     watching   pid  41882
SAMPLES   24  every  15000 ms
INCIDENT  none
META      incidents off  —  calls this hour  <span class="ok">0</span> / 4
ASSESS    quiet

<span class="dim">Healthy recurring work uses no model calls.
Starting granted no write and no reboot.</span>`,
  };

  const TUI_CUES = [
    { t: 46, id: "deviceFactory" },
    { t: 64, id: "enrollRun" },
    { t: 76, id: "enrollOk" },
    { t: 94, id: "policy" },
    { t: 120, id: "talk" },
    { t: 132, id: "tool" },
    { t: 146, id: "receipt" },
    { t: 166, id: "resident" },
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
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
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
    { t: 8,   p: [2.15, 1.55, 3.85], l: [0.10, 0.70, 0.10], fov: 32, exp: 1.08 },
    { t: 18,  p: [1.15, 1.05, 2.35], l: [0.22, 0.52, 0.14], fov: 30, exp: 1.12 },
    { t: 32,  p: [0.72, 0.86, 1.72], l: [0.28, 0.52, 0.12], fov: 28, exp: 1.10 },
    { t: 46,  p: [0.78, 0.90, 1.82], l: [0.20, 0.52, 0.12], fov: 29, exp: 1.08 },
    { t: 64,  p: [0.92, 0.92, 1.78], l: [0.38, 0.52, 0.18], fov: 30, exp: 1.10 },
    { t: 94,  p: [1.05, 1.05, 2.05], l: [0.28, 0.58, 0.12], fov: 32, exp: 1.12 },
    { t: 120, p: [0.85, 0.92, 1.78], l: [0.28, 0.54, 0.12], fov: 29, exp: 1.10 },
    { t: 146, p: [0.90, 0.95, 1.85], l: [0.28, 0.58, 0.16], fov: 29, exp: 1.10 },
    { t: 166, p: [2.35, 1.65, 4.05], l: [0.05, 0.70, 0.10], fov: 32, exp: 1.00 },
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

    const houseOn = smoother(6.5, 11, t);
    windowLight.intensity = 3.2 * houseOn;
    glow.material.opacity = 0.12 + 0.16 * houseOn;

    congestion = 0;
    if (t >= 16 && t < 46) congestion = smoother(16, 24, t) * (1 - smoother(40, 46, t));
    else if (t >= 156) congestion = 0;
    else congestion = 0.12;

    const cageOn = smoother(94, 104, t);
    cage.scale.setScalar(0.15 + 0.85 * cageOn);
    cageMat.opacity = 0.85 * cageOn;
    ports.forEach((p) => { p.visible = cageOn > 0.35; p.scale.setScalar(clamp(cageOn * 1.2, 0, 1)); });
    rim.intensity = 1.4 * cageOn;

    const enroll = t >= 64 && t < 94;
    vaultLid.rotation.x = enroll ? -1.15 * smoother(64, 70, t) : 0;
    if (t >= 68 && t < 78) {
      keySpark.visible = true;
      const u = smoother(68, 76, t);
      keySpark.position.lerpVectors(
        new THREE.Vector3(0.62, 0.52, 0.28),
        new THREE.Vector3(0.28, 0.52, 0.12),
        u
      );
    } else {
      keySpark.visible = false;
    }

    const enrolled = t >= 76;
    led.material.color.set(enrolled ? 0x8fd0c8 : (t % 1.2 < 0.6 ? 0xc9a227 : 0x3a3010));

    if (t >= 132) pips[0].material.color.set(0x3a2222);
    else pips[0].material.color.set(0x8fd0a8);

    if (t >= 138 && t < 146) {
      rebootPulse = Math.sin((t - 138) * 18) * 0.012;
      portReboot.position.x = 0.64 + rebootPulse;
      cap.material.color.set(0xc96b6b);
    } else {
      portReboot.position.x = 0.64;
      cap.material.color.set(0x8a3a3a);
    }

    receipt.visible = false;

    screen.material.opacity = t < 28 ? 0.15 + 0.25 * (0.5 + 0.5 * Math.sin(t * 6)) : (t < 46 ? 0.12 : 0.28);
    screen.material.color.set(t < 46 && t > 22 ? 0xc9a227 : 0x7ec9d4);

    counter.classList.toggle("show", t >= 164 && t < 176);
    callN.textContent = "0";

    titles.classList.toggle("show", t < 7.6 || (t >= 37.5 && t < 43.5));
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
    requestAnimationFrame(loop);
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
