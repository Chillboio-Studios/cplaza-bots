# CreatorPlaza Bots

A BotGhost-style platform for building and hosting Discord bots with no code.

## Architecture

- **`server.js` + `engine.js` + `auth.js` + `db.js`** — Node.js REST API (Express + MongoDB) that hosts bots in-process via discord.js. Bots are defined as JSON "modules" (trigger → conditions → action blocks) and interpreted by the no-code engine.
- **`client/`** — Flutter app (Android / Windows / Web) with login/register, a bot dashboard, and a visual block editor.

## Run the API server

```bash
npm install
cp .env.example .env   # set MONGODB_URI
npm start              # listens on http://localhost:3000
```

MongoDB is required. Set `MONGODB_URI` in `.env` (local: `mongodb://localhost:27017`,
Atlas: `mongodb+srv://...`). The database name is taken from the URI path
(default `creatorplaza`).

Docker for a local Mongo:
```bash
docker run -d -p 27017:27017 --name mongo mongo:7
```

## Run the Flutter client

```bash
cd client
flutter pub get
flutter run -d windows   # or -d <android-device> / -d chrome
```

The API base URL is set in `client/lib/api.dart` (`ApiClient.baseUrl`).
For an Android emulator use `http://10.0.2.2:3000`; for a physical device use your PC's LAN IP.

## Bot config format

```json
{
  "modules": [
    {
      "id": "...",
      "enabled": true,
      "trigger": { "type": "command", "command": "hello", "description": "Say hi" },
      "conditions": [{ "type": "role", "value": "Member" }],
      "actions": [
        { "type": "send", "content": "Hello {{user}}!" },
        { "type": "embed", "title": "Hi", "description": "...", "color": "#5865F2" }
      ]
    }
  ],
  "settings": { "presence": { "status": "online", "type": "playing", "activity": "..." } }
}
```

- Triggers: `command` (slash), `message` (keyword), `join`, `reaction`
- Conditions: `role`, `channel`, `permission`
- Actions: `send`, `embed`, `react`, `dm`, `addrole`, `removerole`, `kick`, `timeout`
- Variables: `{{user}} {{username}} {{server}} {{channel}} {{message}} {{args}} {{memberCount}}`

## Deployment (Kubernetes / ArgoCD)

Manifests live in `ArgoCD-Deployment-Files/apps/creatorplaza-bots/`
(namespace, certificate, ingress, secrets, workloads with **4 replicas**).
The `creatorplaza` SCRAM user was added to `infra/databases/mongodb.yaml`.

**Multi-replica design:**
- `MONGODB_URI` (MongoDB Atlas) is set in `apps/creatorplaza-bots/secrets.yaml`
  — all replicas share users/sessions/bots/shares.
- Exactly one replica wins a Mongo lease leader election and hosts the
  Discord bots; a reconciler (3s) converges `desired_status`/`config_version`
  so deploy/stop/edit calls on ANY replica take effect cluster-wide. Failover
  is automatic — if the leader pod dies, another takes over within ~10-15s and
  redeploys all online bots.

**One-time setup before sync:**
1. Build & push the image:
   `docker build -t ghcr.io/chillboio-studios/creatorplaza-bots:latest .`
   (keel.sh polls `:latest` every 15s and rolls the deployment).
3. Commit & push `ArgoCD-Deployment-Files` — the ApplicationSet deploys it.

**Env vars:** `MONGODB_URI`, `PORT` (3000), `PUBLIC_URL`
(https://botapi.creatorplaza.nl — used for share links), `ADMIN_USERNAMES`.

**Custom bots (premium):** `k8s.js` manages per-user pods in the
`custom-bots` namespace (manifests in `ArgoCD-Deployment-Files/apps/custom-bots/`).
Env vars: `CUSTOM_BOTS_NAMESPACE`, `RUNNER_IMAGE_PREFIX`
(`ghcr.io/chillboio-studios/cpb-runner`), `CUSTOM_BOT_BASE_DOMAIN`
(`custom.creatorplaza.nl`), `CUSTOM_BOT_LIMIT` (default 3).
Runner images are built by `.github/workflows/runners.yml` → GHCR
(`cpb-runner-python|nodejs|java|cpp`). See `apps/custom-bots/README.md` for
the required wildcard DNS record.

## API

| Method | Route | Description |
|---|---|---|
| POST | `/api/auth/register` | Create account → `{user, token}` |
| POST | `/api/auth/login` | Login → `{user, token}` |
| POST | `/api/auth/logout` | Invalidate session |
| GET  | `/api/me` | Current user |
| GET  | `/api/bots` | List your bots |
| POST | `/api/bots` | Create bot `{name, token, config}` |
| GET  | `/api/bots/:id` | Get one bot |
| PUT  | `/api/bots/:id` | Update bot |
| DELETE | `/api/bots/:id` | Delete bot |
| POST | `/api/bots/:id/deploy` | `{action: start\|stop\|restart}` |
| GET  | `/api/custom-bots` | List your custom bots (premium) |
| POST | `/api/custom-bots` | Deploy repo → pod `{name, repo_url, branch, language, startup_script, port, domain\|subdomain, env}` |
| GET/PUT/DELETE | `/api/custom-bots/:id` | Get / update / delete |
| POST | `/api/custom-bots/:id/restart` | Restart pod (fresh clone) |
| GET  | `/api/custom-bots/:id/logs?tail=` | Pod logs |
| GET  | `/api/custom-bots/:id/status` | Live k8s status |

Auth via `Authorization: Bearer <token>` header.

## Plans & admin

- **Free**: 1 bot, 15 commands max (enforced server-side on create/update)
- **Premium**: unlimited bots & commands, plus custom bots — deploy any public
  GitHub repo (python/nodejs/java/cpp) as its own pod with optional domain +
  automatic SSL
- `/admin` — web admin panel (login with an admin account). Admins are set via
  `ADMIN_USERNAMES=user1,user2` env var at startup, or promoted via
  `POST /api/admin/users/:id/role {"role":"admin"}`.
- Admin API (requires admin): `GET /api/admin/stats`, `GET /api/admin/users`,
  `GET /api/admin/bots`, `POST /api/admin/users/:id/plan`,
  `POST /api/admin/users/:id/role`.
