# Security notes

Review of this setup as of 2026-09-29 (#12 added 2026-10-01): ZCode 3.14.4, Selkies 2.0.0 (`baseimage-selkies:ubunturesolute`), OrbStack. Findings marked **verified** were tested against a running container. The others come from reading the config.

> [!CAUTION]
> **Never expose this setup to the internet as it is.** Nothing here is built to be reachable beyond your own Mac. The desktop has no authentication, the API has no key by default, and either one gives control of an agent that has shell access to your mounted projects. Don't publish ports, port-forward, put it behind a public reverse proxy or tunnel it out. This project is unofficial and unsupported, and this review is best effort, not a guarantee.

## Threat model in one paragraph

ZCode is an AI coding agent. It reads your code, runs shell commands and installs packages, so treat everything inside the container as **potentially hostile**. A prompt injection in a README, a malicious npm `postinstall` or a compromised model response all end up running code as the agent. The container keeps that code away from your Mac. It does **not** keep it away from anything you mount, or from anything the network can reach. A second attacker is **web pages you visit on your Mac**, which can try to talk to the unauthenticated services this setup runs locally.

The boundaries that matter:

| Boundary | Strength |
|---|---|
| Container → macOS | Good: OrbStack runs containers in a Linux VM, the container isn't privileged, and it gets no Docker socket or host PID/IPC |
| Container → **mounted projects** | **None, by design.** Read-write, including `.git/` |
| Container → network, internet and the Mac's services | **Open**, like any Docker container |
| Your Mac's browser → Selkies desktop | **No authentication.** Only OrbStack's routing limits who can reach it |
| Agent user → root inside the container | **None.** `abc` has passwordless sudo |

---

## High

### 1. Any website you visit can drive the ZCode desktop (cross-site WebSocket hijacking), verified

Selkies runs with `access open` (no auth), and its WebSocket at `/api/websockets` accepts connections from **any `Origin`**:

```
curl -sk --http1.1 -H 'Origin: https://evil.example' -H 'Upgrade: websocket' ... https://zcode.orb.local/api/websockets
→ 101 Switching Protocols
```

WebSockets aren't covered by CORS. JavaScript on any page open in your Mac browser could connect to `wss://zcode.orb.local/api/websockets` and send keyboard and mouse input. That means typing into ZCode's terminal or agent and running commands with full access to your mounted projects. It could also read your screen through the video stream. The attacker has to guess the hostname, which is trivial because it's always `zcode.orb.local`.

- **Partial mitigation today:** recent Chrome builds ask before public sites reach private-network addresses (*Local Network Access*). Safari and Firefox don't.
- **Fix, not yet applied:** make nginx reject `/api` and `/pelorus` requests whose `Origin` isn't `https://zcode.orb.local`. Also set `CUSTOM_USER` and `CUSTOM_PASSWORD` as defense in depth. Basic auth alone isn't enough, because browsers reuse cached credentials on cross-site WebSocket handshakes.
- **Until then:** run `./run.sh --stop` when you're not using ZCode. `restart: unless-stopped` currently keeps it running whenever OrbStack is up.

### 2. The agent can plant code that later runs on your Mac, verified

Mounted folders are read-write, and inside the container they're owned by the agent user. That includes `.git/hooks/`, which the agent can write to. Anything the agent writes that **your Mac later executes** escapes the container:

- `.git/hooks/*` runs on your next `git commit` or `git checkout` on the Mac.
- Changes to `package.json` scripts, `Makefile`, `.envrc` (direnv), `.vscode/tasks.json` / `settings.json`, `.husky/`, `.npmrc`, `pyproject.toml` build hooks and similar files.
- JavaScript inside `node_modules`, if the agent ran `npm install` in the container and you then run the project on the Mac. Native binaries fail across OSes, but plain JS runs fine.

This is inherent to giving any agent write access to a repo. The container doesn't protect you here.

- **Mitigations:**
  - Review diffs (`git status`, `git diff`) before running anything the agent touched, and especially check `git diff --stat -- .git/hooks .husky .vscode package.json`.
  - On the Mac, set `git config --global core.hooksPath ~/.githooks`, so repo-local `.git/hooks` are ignored.
  - Don't let the Mac and the container share `node_modules` (see the README).
  - Mount only the projects you're actively working on.

### 3. `login.sh` opens whatever URL the container gives it

`login.sh` reads `/tmp/zcode-open-url` from the container and passes it to macOS `open`. Code in the container, such as a malicious package the agent installed, can write that file. On macOS, `open` also accepts `file://` paths (which can launch apps), `x-apple.systempreferences:` and any registered URL scheme. If you run `./login.sh` after the container has been compromised, it will open whatever the attacker put there.

- **Fix, not yet applied:** accept only `https://` URLs, ideally only Z.ai hosts, and print the URL before opening it.

---

## Medium

### 4. No boundary between the agent and root in the container, verified

The agent process runs as `abc`, and `abc` has passwordless `sudo` (a LinuxServer base-image default). Anything the agent runs can become root in the container. Root in a non-privileged OrbStack container still can't reach macOS without a kernel exploit, so this matters mainly for defense in depth. It also means nothing inside the container is safe from the agent, including the ZCode binary, the nginx config and your stored credentials.

- **Fix, if wanted:** remove `abc` from sudoers at build time. This breaks Selkies features that rely on sudo, such as installing apps from its panel, so test it first.

### 5. Credentials are stored effectively unencrypted

`--password-store=basic` makes Electron's `safeStorage` use a fixed, well-known key, so your Z.ai login tokens in the `zcode-config` volume (`/config/.config/ZCode`, `/config/.zcode`) are effectively plaintext. They're readable by the agent and by anyone with Docker access on your Mac (`docker run -v zcode-docker-webui_zcode-config:/x ...`). This is the standard trade-off for Electron in containers, since the alternative is running a keyring daemon in the same container, which the agent could read anyway.

- **Mitigation:** treat the volume as a secret. To revoke a stolen token, log out or rotate it at z.ai, then run `docker volume rm zcode-docker-webui_zcode-config`.

### 6. Unrestricted network access, verified

The container has full internet access and can reach:
- **Services on your Mac** through `host.docker.internal` / `host.orb.internal`. Local databases, Ollama, dev servers and admin UIs bound to `localhost` are reachable, because OrbStack forwards those names to the Mac's loopback.
- **Your LAN**: routers, NAS, printers.
- **Other OrbStack containers** through their published ports or `*.orb.local`.

This gives any code in the container a path for **exfiltrating** your source and `.env` secrets, and for pivoting to local services that assume "localhost means trusted".

- **Mitigations:**
  - Don't leave sensitive unauthenticated services on the Mac's localhost while ZCode is running.
  - Keep secrets out of mounted folders, or at least out of the projects you mount.
  - If you want a hard limit, set `internal: true` on a dedicated compose network together with an egress proxy that only allows the model API and package registries. Not implemented.

### 7. XQuartz mode: X11 has no isolation

- **Any X client can see every window:** it can read keystrokes (keylogging), take screenshots of all X windows and inject input. `xhost +localhost` admits **every** OrbStack container and local process, not just this one.
- **Enabling "Allow connections from network clients"** makes XQuartz listen on TCP 6000. Only `xhost` keeps other hosts on your network out.
- **The README's troubleshooting fallback `xhost +` removes even that**, letting anyone on your Wi-Fi connect to your X server. Use it only briefly to debug, and run `xhost -` afterwards.
- **Prefer browser mode.** If you use XQuartz, quit it when you're done so the listener closes.

### 8. DevTools Protocol (`ZCODE_CDP=1`) is full remote control

When enabled, port 9223 (through `socat`) gives **unauthenticated, complete control** of ZCode to any local process on the Mac or any container that can reach `zcode.orb.local`: arbitrary JS in the app, reading tokens, driving the agent. It's off by default, so turn it on only while an automation actually needs it.

Also note: Chromium rejects DevTools HTTP requests whose `Host` header isn't an IP address or `localhost`, as a DNS-rebinding defense. Connecting through `http://zcode.orb.local:9223` may therefore be refused. If it is, use the container IP (`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zcode`). That is a usability issue, not a hole, so don't work around it by exposing the port more widely.

### 12. The API endpoint spends your plan, and in agent mode runs the agent

`https://zcode.orb.local/api/v1` (`ZCODE_API=1`, the default) has **no key unless you set `ZCODE_API_KEY`**. Anything that can reach `zcode.orb.local` can use it: processes on your Mac and other OrbStack containers. Web pages are handled separately:

- **Browser pages are refused.** Requests that carry an `Origin` header are rejected unless it's listed in `ZCODE_API_ORIGINS`, and POSTs must be `application/json`, which a cross-site form can't send without a CORS preflight that the server doesn't grant. Unlike Selkies' WebSocket (#1), the API can't be driven from a site you visit.
- **Chat mode (the default)** removes every tool the model reported seeing, including the workflow tool `EvalWorkflowSnippet`, which runs code. It runs in an empty scratch folder in build mode, so any tool added later would need approval, which a headless run can't give. Verified: asked to list its tools, the model answers `NONE`. A plugin or ZCode update could still add tools, so treat a prompt as potentially able to read files inside the container, including the login tokens (#5), and return them in the response. The response only goes back to whoever sent the request.
- **The CLI reuses the desktop login.** `zcode-cli-sync` writes one non-secret entry (your Z.ai user id) into the shared credential store, so the CLI picks up the coding-plan key the desktop already cached. No token leaves the store. It loads ZCode's own credential functions from the CLI bundle, so a ZCode update may break it, and it then fails with an error rather than doing anything else.
- **Agent mode (`ZCODE_API_AGENT=1`)** lets any caller run the agent in any directory, in `yolo` mode if they ask. That is the same power as the desktop: shell access to your mounted projects (#2). Turn it on only together with `ZCODE_API_KEY`.

---

## Low

### 9. Supply chain is only pinned by tag
- **The ZCode `.deb`** is downloaded over HTTPS with **no checksum**. A compromised CDN or tampered file would be installed as-is. Fix: `ADD --checksum=sha256:<hash>` in the Dockerfile.
- **`baseimage-selkies:ubunturesolute` and `node:24-slim` are moving tags** that LinuxServer and Docker rebuild regularly. `--rebuild` picks up whatever they currently point to. Fix: pin with `@sha256:` digests and bump them on purpose.
- **Chromium is bundled inside ZCode**, so browser security fixes arrive only when Z.ai ships a new version. `--no-sandbox` means a renderer exploit runs code as `abc` straight away. The container is the only remaining sandbox, which is why the boundaries above matter.

### 10. Clipboard sharing
Selkies syncs the clipboard both ways while the tab has focus. Whatever you copy on the Mac, such as passwords and 2FA codes, can become readable inside the container, and the agent can place content on your Mac clipboard. You can turn clipboard sync off in the Selkies sidebar when you don't need it.

### 11. Minor
- **Selkies extras are reachable:** the apps panel (`selkies-proot`), print spooling, audio and virtual gamepads. With finding 1 in place, the apps panel also lets whoever holds the WebSocket install software. Harden with the Selkies hardening variables if you care; see the *Security and Hardening* page in the LinuxServer docs.
- **Your git name and email are passed into the container** as `GIT_*` variables so commits are attributed to you. They're visible to the agent and written to `compose.override.yaml`, which is git-ignored.
- **`run.sh` writes folder paths into YAML.** It rejects `"`, `$` and `\`. A folder name containing a newline could still break the generated file. That would be self-inflicted, not exploitable from the container.

---

## Plain Docker (without OrbStack, untested)

Everything above assumes OrbStack on macOS. With `ZCODE_RUNTIME=docker`, `compose.docker.yaml` publishes ports 3000 (the desktop and API) and 9223 (DevTools). It binds them to **127.0.0.1 only**, and that binding is the only thing keeping both off your network. Don't change it to a bare `3000:3000`: on Linux that listens on every interface and bypasses `ufw`. On Docker Engine for Linux there is also no VM between the container and your host, so the "Container → macOS: Good" boundary above becomes "container → host kernel", which is weaker. This path hasn't been tested. Treat it as experimental.

## Reviewed and OK

- **No ports are published on the Mac.** Selkies (3000/3001) is reachable only through OrbStack's private container network (`zcode.orb.local`), not from your LAN (`docker port zcode` is empty).
- **The container isn't privileged:** no added capabilities, no Docker socket, and the bundled dockerd isn't started.
- **`zcode-callback`** copies the environment of the running ZCode process, which the agent controls. It drops privileges with `setpriv` **before** applying that environment, so variables like `LD_PRELOAD` can't run as root.
- **The callback URL in `login.sh`** has to start with `zcode://`, and it's passed to `docker exec` as a single argument, with no shell interpolation.
- **Settings and credentials live in a named volume**, not in the repo. `.env` and `compose.override.yaml` are git-ignored and docker-ignored.

## Suggested next steps (not yet applied)

1. Add an nginx `Origin` check for `/api` and `/pelorus` (fixes #1), plus optional `CUSTOM_USER`/`CUSTOM_PASSWORD`.
2. Allow only `https://` URLs in `login.sh` (fixes #3).
3. Pin the ZCode `.deb` with `ADD --checksum` and the base images by digest (#9).
4. Change `restart: unless-stopped` to `restart: "no"`, so the desktop doesn't run unattended.
5. On the Mac, set `git config --global core.hooksPath ~/.githooks` (#2).
6. Optionally remove passwordless sudo (#4) and restrict egress (#6).
