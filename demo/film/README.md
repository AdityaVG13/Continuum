# Continuum film

Three-minute silent picture for the hackathon VO.

```sh
cd demo/film
python3 -m http.server 8767 --bind 127.0.0.1
```

Open `http://127.0.0.1:8767/` to rehearse (teleprompter on the right).
Open `http://127.0.0.1:8767/?record=1` to record: stage only, autoplay. Fullscreen Chrome first.

Space play/pause. `R` hides the desk. `1`–`8` jumps scenes. Arrows skip 5s.

Screen-record the 16:9 stage. Record voice from
`docs/internal/DEMO_SCRIPT.md`. Mix later. Do not live-narrate the first take.
