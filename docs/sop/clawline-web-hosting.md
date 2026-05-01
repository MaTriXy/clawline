# Clawline web client hosting

The Clawline web client is a standalone browser application. Do not install or serve its built root from OpenClaw's workspace webroot.

## Service boundary

- Clawline provider / OpenClaw service: owns the provider API, WebSocket, upload, terminal, and provider static workspace routes. In local development this commonly listens on port `18800`.
- Clawline web client: owns the browser app shell and static Vite build. It should be installed and served as its own service/root.

The web client may connect to the provider at `ws(s)://<provider-host>:18800/ws` and provider HTTP APIs derived from that base, but its HTML/JS/CSS assets should not live under the provider's `/www` static workspace route.

## Usual install shape

A production-style host should use a normal app/static-service layout, for example:

- app/build root: `/srv/clawline-web` or `/opt/clawline-web`
- served files: `/srv/clawline-web/dist` after `npm run build`
- service config: systemd unit on Linux, LaunchDaemon on macOS, or the host's existing process manager
- reverse proxy: Caddy/nginx/Traefik if TLS, host routing, or same-origin proxying is needed

Avoid paths under `~/.openclaw` or `~/openclaw` for the web client install root. Those belong to OpenClaw runtime/config and the OpenClaw installation, not the Clawline web client service.

## Deployment pattern

Build the app in a release checkout or CI job, then copy only the static output into the service root.

```bash
npm ci
npm run build
rsync -a --delete dist/ /srv/clawline-web/dist/
```

Serve `/srv/clawline-web/dist` with the host's normal static-file service. For an SPA, unknown routes should fall back to `index.html`.

Example Caddy site:

```caddyfile
clawline-web.example.com {
  root * /srv/clawline-web/dist
  try_files {path} /index.html
  file_server
}
```

Example systemd unit if using Vite preview as a lightweight internal service rather than a static web server:

```ini
[Unit]
Description=Clawline web client preview
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/srv/clawline-web/current
ExecStart=/usr/bin/npm run preview -- --host 0.0.0.0 --port 4173
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Use the static web server pattern for production. Use the preview-service pattern only for temporary/internal installs.

## TARS artifact install

On TARS, `scripts/deploy/clawline-web-tars.sh` builds the web client and installs only static artifacts under `~/Library/Application Support/ClawlineWeb` by default. It also writes a Caddyfile with SPA fallback so deep links under `/pair` and `/chat/...` resolve to `index.html`.

The script does not write, load, unload, or restart LaunchAgents unless explicitly opted in:

```bash
scripts/deploy/clawline-web-tars.sh --manage-service
```

## Local preview

For development or temporary verification, serve this repo's built `dist/` using Vite preview or another static server from the web-client checkout. Keep that preview separate from the provider on `18800`.

```bash
npm run build
npm run preview -- --host 0.0.0.0 --port 4173
```

The provider URL entered into the pairing screen can still point at the Clawline provider, e.g. `ws://<provider-host>:18800/ws`.
