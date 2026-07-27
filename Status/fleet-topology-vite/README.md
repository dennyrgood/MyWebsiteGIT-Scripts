# fleet-topology-vite

A React/Vite app that renders an interactive SVG diagram of the fleet's
network topology — machines, links, and per-node service lists (SI, SC, SW,
AMSDT, MM, ZB, W, HUB24, NAS, etc.). The diagram itself lives in
`src/App.jsx`.

Scaffolded with `npm create vite@latest` (react template); not otherwise tied
to the rest of this repo — it's a standalone Node/npm project.

## First-time setup

Requires Node.js (`brew install node` on macOS if you don't have it).

```
cd Status/fleet-topology-vite
npm install
```

`npm install` only needs to be run once (or again if `package.json`
dependencies change) — it populates `node_modules/`.

## Running it (dev server with hot reload)

```
npm run dev
```

This starts a local dev server, prints a URL (typically
http://localhost:5173/) — open that in a browser. Leave this command running
in its terminal; it watches files and hot-reloads the page automatically on
save, so you don't restart it between edits.

To stop it, Ctrl-C in that terminal.

## Making changes / viewing a new version of the JSX

There's no build step to "see" a change — just overwrite the file and save,
with the dev server running in a terminal.

To view a new JSX snippet (e.g. one pasted from a chat):

1. Save/copy it to this exact path, overwriting what's there:
   `/Users/dennishmathes/repos/scripts/Status/fleet-topology-vite/src/App.jsx`
2. Make sure the dev server is running:
   ```
   cd /Users/dennishmathes/repos/scripts/Status/fleet-topology-vite
   npm run dev
   ```
   (skip this if it's already running in another terminal — leave it running
   across edits, don't restart it per change)
3. Open the URL it prints (typically http://localhost:5173/) and it'll show
   the new version. Saving `App.jsx` again while the server is running
   hot-reloads the page automatically — no restart, no manual refresh.

No "copying files to a web server" step is needed for local viewing — Vite's
dev server serves the files directly from this directory.

## Production build (static files, e.g. to host elsewhere)

```
npm run build
```

Outputs static HTML/JS/CSS into `dist/`. To preview that build locally:

```
npm run preview
```

To actually host it (e.g. serve `dist/` over Tailscale from another
machine), copy `dist/` to wherever a static file server points, or run any
static server against it, e.g. `npx serve dist`.

## Lint

```
npm run lint
```
