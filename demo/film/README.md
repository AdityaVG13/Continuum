# Continuum film

Three-minute picture for the hackathon VO: a Three.js set plus the setup
wizard's real frames. Script and mux steps: `docs/internal/DEMO_SCRIPT.md`.

```sh
cd demo/film
python3 -m http.server 8767 --bind 127.0.0.1
```

Open `http://127.0.0.1:8767/` to rehearse (teleprompter on the right),
`?record=1` for the stage only. Space play/pause, `R` hides the desk,
`1`-`8` jump scenes, arrows skip 5 s.

Offline render (deterministic, frame-stepped in the system Chrome, encoded by
ffmpeg):

```sh
npm i --prefix /tmp/film-render playwright-core
PLAYWRIGHT_CORE=/tmp/film-render/node_modules/playwright-core \
  node demo/film/render.mjs demo/film/out/continuum-film-silent.mp4 30 180
```
