# Agent Flow promo video

Source for the 35-second video on the [Agent Flow website](https://ethansk.github.io/AgentFlow/#video).

- `scene.html` is the whole video as one 1920×1080 web page. `window.renderAt(seconds)` draws any
  moment; nothing animates on its own, so every frame is reproducible.
- `render.mjs` opens the scene in headless Google Chrome, captures every frame at 30 fps with 2×
  supersampling, and encodes `docs/assets/agentflow-promo.mp4` (H.264, no audio) plus the page
  poster `docs/assets/agentflow-promo-poster.jpg`.

## Render

Needs Node.js, Google Chrome and ffmpeg.

```sh
cd promo
npm install
node render.mjs                  # full video and poster (a few minutes)
node render.mjs --stills --scale 1        # quick PNG stills in promo/out/
node render.mjs --stills --scale 1 9.6 18 # stills at chosen seconds
```

## Keep it truthful

The captions repeat claims the website already makes, and the dictation, selection and screenshot
path are the website demo's invented example. When the site's demo or those claims change, update
the scene to match and re-render. Never put real selections, paths or messages in the scene.
