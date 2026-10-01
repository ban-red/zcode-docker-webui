# Performance notes

Measured on 2026-09-29 on the running `zcode` container: Apple Silicon (12 cores visible to OrbStack), ZCode 3.14.4, Selkies 2.0.0, browser mode. Everything runs natively on arm64, with no Rosetta or x86 emulation.

## What we measured

| State | Container CPU (`docker stats`) |
|---|---|
| ZCode tab **visible**, while in use (old defaults: Retina, 60 fps, x264 Turbo) | **~286%**, about 3 cores · 1.64 GiB |
| ZCode tab **hidden** or in the background | **~5%** |
| ZCode tab **visible**, **new defaults** (1×, 30 fps, JPEG, no Turbo, no audio) | **~64–73%** · ~0.97 GiB |

With the new defaults the stream runs at `1402x968 | FPS: 30 | Mode: JPEG | Stripes: 4`. The biggest consumers are selkies at ~31% (was ~164%) and ZCode's two Chromium processes at ~17% + ~12% (were ~72% + ~63%). That's about **4× less CPU** and **~40% less memory**. The before and after activity weren't identical, so treat this as a rough comparison, not a benchmark.

When the tab is hidden, the Selkies web client sends `STOP_VIDEO` and the encoder stops. So nearly all the CPU goes into **producing the live video stream**, not into ZCode itself.

Breakdown while visible (`top` inside the container):

| Process | CPU | What it is |
|---|---|---|
| `selkies` | **~164%** | Screen capture and **software H.264 encode** (x264, about 5 busy `wl-encode` threads) |
| `zcode` (renderer) | ~72% | Chromium drawing ZCode's UI on the CPU |
| `zcode` (GPU/viz process) | ~63% | Chromium compositing on the CPU; `--disable-gpu`, because the OrbStack VM has no GPU |
| `zcode-cli`, `ZCode` main, pulseaudio, labwc, nginx | ~25% | The agent backend and small overheads |

The settings Selkies logged for the stream:

```
Res: 2408x1780 | FPS: 60.0 | Mode: H264 (x264) FullFrame | CRF: 25
Readback capture ... rendered in software (Pixman) ... (no GPU renderer)
Session compositor screen 0 ('primary') scaled to 2.0
```

## Why it's expensive

It's a stack of multipliers, all running on the CPU:

1. **Retina resolution.** The browser tab asks for its size in physical pixels (2408×1780, about 4.3 MP) at scale 2.0. Chromium rasterizes, composites, captures and encodes **4× the pixels** of a 1× display. One earlier session even ran at 3620×2960 (10.7 MP) while the window was larger.
2. **"Turbo" streaming mode is on by default** (`video_streaming_mode=true`: "encode every frame like a traditional video encoder"). The encoder does full-frame H.264 at up to 60 fps. Paint-over and CRF only change quality, not how much work is done.
3. **No hardware anywhere.** OrbStack gives containers no GPU and no video encoder. The log shows NVENC and VA-API failing and falling back to x264, and the compositor running on Pixman (software). Chromium runs with `--disable-gpu`. That's unavoidable in a Mac VM today, so the only lever is doing *less work*.
4. **60 fps.** Frame-for-frame, that doubles the cost of 30 fps. An IDE rarely needs more than 30.

## Suggested optimizations (ranked by expected impact)

The impact figures are **estimates from pixel and frame counts, not yet measured**. See "How to measure" below.

### 1. Stream at 1× instead of Retina: roughly 3–4× less work everywhere
- **Where it helps:** pixel count drives *every* stage (Chromium raster, compositing, capture, encode). Going from 2408×1780 to 1204×890 is 4× fewer pixels.
- **How:**
  - At runtime, turn off HiDPI / "scale to device pixel ratio" in the Selkies sidebar.
  - To lock it, set `SELKIES_MANUAL_WIDTH` and `SELKIES_MANUAL_HEIGHT` (for example 1600×1000). The browser then scales the stream to fit the window.
- **Trade-off:** text is noticeably softer on a Retina screen. A middle ground is a fixed ~1.5× size.

### 2. Encode only what changed, not every frame: large win when idle, moderate when typing
- **Where it helps:** an IDE is mostly static. Damage-based encoding only does work when pixels change.
- **Options:**
  - `SELKIES_VIDEO_STREAMING_MODE=false` turns off Turbo.
  - Or switch the encoder to one that works in stripes: `SELKIES_ENCODER=jpeg` (libjpeg-turbo, stripes, often cheaper and sharper for text than x264 when there's no GPU), or `SELKIES_ENCODER=h264enc-striped`.
- **Trade-off:** JPEG uses more bandwidth. That doesn't matter here, because the "network" is local to your Mac. Scrolling may look a little less smooth.

### 3. Cap at 30 fps: up to 2× less encoding during motion
- **How:** `SELKIES_FRAMERATE=30` or `"30,8-60"`, or lower it in the sidebar.
- **Possible bonus:** the Wayland compositor's frame pacing follows the capture rate, so Chromium may also draw less often.

### 4. Make Chromium draw less: ZCode renderer and viz, about 135% today
- **Reduce animations:** add `--force-prefers-reduced-motion` through `ZCODE_FLAGS`, so spinners and transitions that honour `prefers-reduced-motion` stop redrawing continuously.
- **Close idle panes:** turn off live previews and animated status UI inside ZCode where possible.
- **Tab state is decisive:** in a hidden tab everything stops (5%). A tab that's visible but ignored is the expensive case, because Selkies keeps capturing.

### 5. Put a ceiling on it
- **Cap the container:** add `cpus: 4` (or similar) to the `zcode` service in `compose.yaml`. The stream then degrades (lower effective fps) instead of taking over your Mac.
- **Cap OrbStack:** alternatively, OrbStack → Settings → System → CPU limit caps *all* of OrbStack.

### 6. Small wins
- **Audio:** `SELKIES_AUDIO_ENABLED=false`. ZCode doesn't need sound, and this removes the Opus encoder and the pulseaudio capture loop (a few %).
- **Smaller browser window:** in the default "sized by the client" mode, a smaller window directly means fewer pixels.

### Alternative: XQuartz mode
- **Why it can be cheaper:** `./run.sh --x11` has no video encoder at all. Chromium still renders on the CPU, then sends X11 draw commands to XQuartz.
- **Trade-offs:**
  - The Linux side usually uses much less CPU than the stream, but some of the cost moves to XQuartz on the Mac.
  - XQuartz is 1× only (no Retina) and gets laggy on large repaints.
  - It has the security caveats in [SECURITY.md](SECURITY.md) (#7).
- **Worth trying** if CPU matters more to you than smoothness.

## Applied defaults

All of the suggestions above are now the defaults. Each one is a variable you can set in `.env` (template: `.env.example`), and `./run.sh` applies changes:

| Suggestion | Variable → Selkies/Chromium setting | Default | Undo |
|---|---|---|---|
| #1 1× instead of Retina | `ZCODE_SCALE_1X` → `SELKIES_USE_CSS_SCALING` | `true` | `false` |
| #1 fixed size (optional) | `ZCODE_WIDTH`/`ZCODE_HEIGHT` → `SELKIES_MANUAL_*` | `0` (follow window) | — |
| #2 encode only changes | `ZCODE_TURBO` → `SELKIES_VIDEO_STREAMING_MODE` | `false` | `true` |
| #2 encoder that works in strips | `ZCODE_ENCODER` → `SELKIES_ENCODER` | `jpeg,h264enc-striped,h264enc` | `h264enc` |
| #3 frame rate | `ZCODE_FPS` → `SELKIES_FRAMERATE` | `30` | `60` |
| #4 fewer animations | `ZCODE_REDUCED_MOTION` → `--force-prefers-reduced-motion` | `1` | `0` |
| #5 CPU ceiling | `ZCODE_CPUS` → compose `cpus` | `4` | e.g. `12` |
| JPEG quality while moving | `ZCODE_JPEG_QUALITY` → `SELKIES_JPEG_QUALITY` | `70` (Selkies: 40) | `40` |
| #6 no audio | `ZCODE_AUDIO` → `SELKIES_AUDIO_ENABLED` | `false` | `true` |

- **Value syntax** follows Selkies:
  - `ZCODE_FPS="30,8-60"` sets the start value and the sidebar range. `"30-30"` locks it.
  - A single `ZCODE_ENCODER` value locks the encoder.
- **Measured:** see the table at the top (~286% → ~70% CPU).

## Tuning for text sharpness

Speed and sharpness pull against each other, because both come down to pixels and bits per frame. These are the knobs that affect how text looks, roughly in order of effect. The setting names and defaults are read from Selkies 2.0.0. The effects haven't been benchmarked here.

### 1. Resolution decides most of it
- **Full Retina:** `ZCODE_SCALE_1X=false`. Text is as sharp as the Mac screen, at about 4× the pixels. Pair it with a lower frame rate (`ZCODE_FPS=15` or `"15,8-30"`) to claw some CPU back. An IDE rarely needs more.
- **Middle ground:** lock a size with `ZCODE_WIDTH`/`ZCODE_HEIGHT` (for example `1800`×`1200`). The browser scales it to the window, so text is sharper than 1× and cheaper than Retina. Match the window's aspect ratio, or you get letterboxing.
- **UI scale:** `SELKIES_SCALING_DPI` (96, 120, 144, … 288) enlarges the desktop's UI instead of changing the stream size. It helps with small text at 1×, but it isn't mapped in `compose.yaml` (see "Setting a Selkies option that has no `ZCODE_*` variable" below).

### 2. Paint-over: sharp when still, cheap when moving
- Selkies sends moving content at lower quality, then repaints a static screen at high quality. This is on by default (`use_paint_over_quality`), and it is why text looks soft while scrolling and then snaps sharp.
- **JPEG:** Selkies starts at quality 40 while moving and 90 once still. We raise the first to 70 (`ZCODE_JPEG_QUALITY`), so text is less soft while scrolling and straight after returning to a hidden tab. Raise it further for sharper text, at more CPU (bandwidth is free here, since the link is local to your Mac). Lower it back toward 40 if CPU matters more.
- **H.264:** the equivalents are CRF 25 while moving and 18 once still (lower is sharper), with 5 burst frames on repaint.
- All of these can be changed live in the Selkies sidebar. The server-side names are `SELKIES_JPEG_QUALITY`, `SELKIES_PAINT_OVER_JPEG_QUALITY`, `SELKIES_VIDEO_CRF`, `SELKIES_VIDEO_PAINTOVER_CRF` and `SELKIES_VIDEO_PAINTOVER_BURST_FRAMES`. Each takes a start value, a range, or both (`"70,1-100"`), and `"70-70"` locks it.

### 3. Pick the encoder for text
- **`jpeg` (default):** no chroma or motion artefacts, and it is cheap on a CPU-only host. The best choice for code unless you scroll a lot at low quality.
- **`h264enc-striped`:** better compression when moving, but 4:2:0 chroma blurs coloured text and syntax highlighting edges.
- **`h264enc`:** full frame. Heavier on CPU, since every frame is encoded.
- **4:4:4 chroma:** `SELKIES_VIDEO_FULLCOLOR=true` keeps coloured text crisp on the H.264 encoders. It works on x264, but the browser's decoder must support it, otherwise Selkies falls back on its own.
- Use the sidebar to compare encoders live. A single `ZCODE_ENCODER` value locks the choice.

### 4. Don't turn on Turbo for sharpness
- `ZCODE_TURBO=true` encodes every frame. It makes motion smoother, but it does nothing for still text, and it costs the most CPU.

### 5. Browser and font side
- Chromium font rendering inside the container can be adjusted through `ZCODE_FLAGS`, for example `--font-render-hinting=none`. This is untested here and a matter of taste, so try it on your screen.

### Presets

| Goal | Settings |
|---|---|
| Fastest (default) | `ZCODE_SCALE_1X=true`, `ZCODE_FPS=30`, `ZCODE_ENCODER=jpeg,...` |
| Sharper text, moderate cost | `ZCODE_WIDTH=1800`, `ZCODE_HEIGHT=1200`, `ZCODE_FPS=20` |
| Sharpest text | `ZCODE_SCALE_1X=false`, `ZCODE_FPS=15`, raise the JPEG quality in the sidebar |

### Setting a Selkies option that has no `ZCODE_*` variable
`compose.yaml` only maps the stream settings in the "Applied defaults" table above. To make any other `SELKIES_*` option the default, add it to the `zcode` service's `environment` in `compose.yaml` and run `./run.sh`:

```yaml
      SELKIES_PAINT_OVER_JPEG_QUALITY: "95,1-100"
      SELKIES_SCALING_DPI: "144"
```

Check the effect with the log line in "How to measure".

## How to measure

Compare settings in the same state: tab visible, ZCode idle, same window size.

```sh
# overall container CPU, 5 samples
for i in 1 2 3 4 5; do docker stats --no-stream --format '{{.CPUPerc}}' zcode; done

# per-process breakdown
docker exec zcode top -b -n 2 -d 3 -o %CPU | awk '/^top/{n++} n==2' | head -15

# what the stream is actually doing (resolution / fps / encoder)
docker logs zcode 2>&1 | grep 'Stream settings active' | tail -1
```

Record the results in the table at the top, so later changes can be compared against this baseline.
