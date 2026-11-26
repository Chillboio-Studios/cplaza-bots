const express = require('express');
const crypto = require('crypto');
const path = require('path');
const auth = require('./auth');
const db = require('./db');
const engine = require('./engine');

const app = express();
const PORT = process.env.PORT || 3000;
const PUBLIC_URL = process.env.PUBLIC_URL || '';

app.set('trust proxy', 1);
app.use(express.json({ limit: '1mb' }));

// CORS — the API is consumed by the Flutter app and web builds
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// ---------- plans & limits ----------
const FREE_MAX_BOTS = 1;
const FREE_MAX_COMMANDS = 15;
const ADMIN_USERNAMES = new Set(
  (process.env.ADMIN_USERNAMES || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean)
);

async function userRow(id) {
  const u = await db.cols.users.findOne({ id: Number(id) });
  return u ? publicUser(u) : null;
}

function publicUser(u) {
  if (!u) return u;
  const { _id, password_hash, salt, ...rest } = u;
  return rest;
}

async function isSuspended(userId) {
  return !!(await userRow(userId))?.suspended;
}

async function suspendUserBots(userId) {
  // desired_status=offline makes the leader's reconciler stop them;
  // stopBot covers the case where this process is the leader.
  const bots = await db.cols.bots.find({ user_id: Number(userId) }).project({ id: 1 }).toArray();
  for (const b of bots) {
    engine.stopBot(b.id);
    await db.cols.bots.updateOne({ id: b.id },
      { $set: { desired_status: 'offline', status: 'offline' } }).catch(() => {});
  }
  return bots.length;
}

async function isAdminUser(user) {
  if (!user) return false;
  if (ADMIN_USERNAMES.has(String(user.username).toLowerCase())) return true;
  const row = await userRow(user.id);
  return row?.role === 'admin';
}

async function isPremium(userId) {
  return (await userRow(userId))?.plan === 'premium';
}

function countCommandsInConfig(configJson) {
  try {
    const c = typeof configJson === 'string' ? JSON.parse(configJson) : (configJson || {});
    return (c.modules || []).filter(m => m?.trigger?.type === 'command').length;
  } catch { return 0; }
}

async function countUserCommands(userId, excludeBotId = null) {
  const rows = await db.cols.bots.find({ user_id: Number(userId) }).project({ id: 1, config: 1 }).toArray();
  let n = 0;
  for (const b of rows) {
    if (excludeBotId !== null && Number(b.id) === Number(excludeBotId)) continue;
    n += countCommandsInConfig(b.config);
  }
  return n;
}

const BOT_FIELDS = { projection: { _id: 0 } };

// ---------- auth helpers ----------
function tokenFromReq(req) {
  const h = req.headers.authorization || '';
  if (h.startsWith('Bearer ')) return h.slice(7).trim();
  const cookie = req.headers.cookie || '';
  const m = cookie.match(/creatorplaza_session=([a-f0-9]+)/);
  return m ? m[1] : null;
}

async function requireAuth(req, res, next) {
  try {
    const user = await auth.getSessionUser(tokenFromReq(req));
    if (!user) return res.status(401).json({ error: 'Not authenticated' });
    if (await isSuspended(user.id)) return res.status(403).json({ error: 'Account suspended' });
    req.user = user;
    next();
  } catch (e) {
    res.status(500).json({ error: 'Auth error' });
  }
}

async function requireAdmin(req, res, next) {
  try {
    const user = await auth.getSessionUser(tokenFromReq(req));
    if (!user) return res.status(401).json({ error: 'Not authenticated' });
    if (!(await isAdminUser(user))) return res.status(403).json({ error: 'Admin only' });
    req.user = user;
    next();
  } catch (e) {
    res.status(500).json({ error: 'Auth error' });
  }
}

// ---------- auth routes ----------
app.post('/api/auth/register', async (req, res) => {
  try {
    const { username, password } = req.body || {};
    const userId = await auth.register(username, password);
    const user = await userRow(userId);
    const token = await auth.createSession(userId);
    res.status(201).json({ user, token });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/auth/login', async (req, res) => {
  try {
    const { username, password } = req.body || {};
    const user = await auth.login(username, password);
    if (await isSuspended(user.id)) return res.status(403).json({ error: 'Account suspended' });
    const token = await auth.createSession(user.id);
    res.json({ user: await userRow(user.id), token });
  } catch (e) {
    res.status(401).json({ error: e.message });
  }
});

app.post('/api/auth/logout', requireAuth, async (req, res) => {
  await auth.destroySession(tokenFromReq(req));
  res.json({ ok: true });
});

app.get('/api/me', requireAuth, async (req, res) => {
  res.json({ user: { ...req.user, ...(await userRow(req.user.id)), admin: await isAdminUser(req.user) } });
});

// ---------- bots routes ----------
app.get('/api/bots', requireAuth, async (req, res) => {
  const bots = await db.cols.bots
    .find({ user_id: Number(req.user.id) }, BOT_FIELDS)
    .sort({ id: -1 }).toArray();
  bots.forEach(b => { b.token = maskToken(b.token); });
  res.json({ bots });
});

app.get('/api/bots/:id', requireAuth, async (req, res) => {
  const bot = await db.cols.bots.findOne(
    { id: Number(req.params.id), user_id: Number(req.user.id) }, BOT_FIELDS);
  if (!bot) return res.status(404).json({ error: 'Bot not found' });
  bot.token = maskToken(bot.token);
  res.json({ bot });
});

app.post('/api/bots', requireAuth, async (req, res) => {
  const { name, token, config } = req.body || {};
  if (!name || !String(name).trim()) return res.status(400).json({ error: 'Name is required' });
  // token may be empty (e.g. imported shared config) — bot can't deploy until set
  let configStr;
  try { configStr = JSON.stringify(config || {}); } catch { return res.status(400).json({ error: 'Invalid config' }); }

  // plan limits
  const botCount = await db.cols.bots.countDocuments({ user_id: Number(req.user.id) });
  const totalCommands = await countUserCommands(req.user.id) + countCommandsInConfig(configStr);
  if (!(await isPremium(req.user.id))) {
    if (botCount >= FREE_MAX_BOTS) {
      return res.status(403).json({ error: `Free plan allows ${FREE_MAX_BOTS} bot. Upgrade to Premium for unlimited bots.` });
    }
    if (totalCommands > FREE_MAX_COMMANDS) {
      return res.status(403).json({ error: `Free plan allows ${FREE_MAX_COMMANDS} commands max. Upgrade to Premium for unlimited commands.` });
    }
  }

  const doc = {
    id: await db.nextId('bots'),
    user_id: Number(req.user.id),
    name: String(name).trim(),
    token: String(token || '').trim(),
    config: configStr,
    status: 'offline',
    desired_status: 'offline',
    config_version: 1,
    created_at: new Date(),
  };
  await db.cols.bots.insertOne(doc);
  const { _id, ...bot } = doc;
  bot.token = maskToken(bot.token);
  res.status(201).json({ bot });
});

app.put('/api/bots/:id', requireAuth, async (req, res) => {
  const existing = await db.cols.bots.findOne(
    { id: Number(req.params.id), user_id: Number(req.user.id) }, BOT_FIELDS);
  if (!existing) return res.status(404).json({ error: 'Bot not found' });
  const { name, token, config } = req.body || {};
  const cleanToken = token && !String(token).includes('•') ? String(token).trim() : undefined;
  let configStr;
  try { configStr = JSON.stringify(config !== undefined ? config : JSON.parse(existing.config)); } catch { return res.status(400).json({ error: 'Invalid config' }); }

  // plan limits (command count across all the user's bots)
  if (!(await isPremium(req.user.id))) {
    const totalCommands = await countUserCommands(req.user.id, existing.id) + countCommandsInConfig(configStr);
    if (totalCommands > FREE_MAX_COMMANDS) {
      return res.status(403).json({ error: `Free plan allows ${FREE_MAX_COMMANDS} commands max. Upgrade to Premium for unlimited commands.` });
    }
  }

  const $set = {};
  if (name !== undefined) $set.name = String(name).trim();
  if (cleanToken !== undefined) $set.token = cleanToken;
  $set.config = configStr;
  // config_version bump makes the leader's reconciler redeploy if desired=online
  await db.cols.bots.updateOne({ id: existing.id }, { $set, $inc: { config_version: 1 } });

  const bot = await db.cols.bots.findOne({ id: existing.id }, BOT_FIELDS);
  bot.token = maskToken(bot.token);
  res.json({ bot });
});

app.delete('/api/bots/:id', requireAuth, async (req, res) => {
  const existing = await db.cols.bots.findOne(
    { id: Number(req.params.id), user_id: Number(req.user.id) }, { projection: { id: 1 } });
  if (!existing) return res.status(404).json({ error: 'Bot not found' });
  engine.stopBot(existing.id); // no-op if this replica isn't the leader
  await db.cols.bots.deleteOne({ id: existing.id }); // leader stops orphans on next reconcile
  res.json({ ok: true });
});

app.post('/api/bots/:id/deploy', requireAuth, async (req, res) => {
  const bot = await db.cols.bots.findOne(
    { id: Number(req.params.id), user_id: Number(req.user.id) }, { projection: { id: 1 } });
  if (!bot) return res.status(404).json({ error: 'Bot not found' });
  const action = (req.body?.action || 'start').toLowerCase();

  if (action === 'stop') {
    await db.cols.bots.updateOne({ id: bot.id }, { $set: { desired_status: 'offline' } });
    return res.json({ ok: true, status: 'offline' });
  }

  // start or restart — bump config_version so the reconciler redeploys
  await db.cols.bots.updateOne({ id: bot.id },
    { $set: { desired_status: 'online' }, $inc: { config_version: 1 } });
  res.json({ ok: true, status: 'deploying' });
});

function maskToken(token) {
  const t = String(token || '');
  if (t.length <= 10) return '••••••••';
  return t.slice(0, 4) + '••••••••' + t.slice(-4);
}

// ---------- config sharing ----------
function shareUrl(req, code) {
  if (PUBLIC_URL) return `${PUBLIC_URL}/share/${code}`;
  const proto = req.headers['x-forwarded-proto'] || 'http';
  const host = req.headers['x-forwarded-host'] || req.headers.host || `localhost:${PORT}`;
  return `${proto}://${host}/share/${code}`;
}

app.post('/api/bots/:id/share', requireAuth, async (req, res) => {
  const bot = await db.cols.bots.findOne(
    { id: Number(req.params.id), user_id: Number(req.user.id) }, BOT_FIELDS);
  if (!bot) return res.status(404).json({ error: 'Bot not found' });
  const code = crypto.randomBytes(6).toString('base64url');
  await db.cols.shares.insertOne({
    code, user_id: Number(req.user.id), bot_id: bot.id,
    name: bot.name, config: bot.config, created_at: new Date(),
  });
  res.status(201).json({ code, url: shareUrl(req, code) });
});

app.get('/api/bots/:id/shares', requireAuth, async (req, res) => {
  const bot = await db.cols.bots.findOne(
    { id: Number(req.params.id), user_id: Number(req.user.id) }, { projection: { id: 1 } });
  if (!bot) return res.status(404).json({ error: 'Bot not found' });
  const shares = await db.cols.shares
    .find({ bot_id: bot.id }, { projection: { _id: 0, config: 0, user_id: 0, bot_id: 0 } })
    .sort({ created_at: -1 }).toArray();
  res.json({ shares: shares.map(s => ({ ...s, url: shareUrl(req, s.code) })) });
});

app.delete('/api/shares/:code', requireAuth, async (req, res) => {
  const share = await db.cols.shares.findOne({ code: req.params.code });
  if (!share) return res.status(404).json({ error: 'Share not found' });
  if (Number(share.user_id) !== Number(req.user.id)) return res.status(403).json({ error: 'Not your share' });
  await db.cols.shares.deleteOne({ code: req.params.code });
  res.json({ ok: true });
});

// public: fetch a shared config
app.get('/api/share/:code', async (req, res) => {
  const share = await db.cols.shares.findOne({ code: req.params.code });
  if (!share) return res.status(404).json({ error: 'Share link expired or invalid' });
  let config;
  try { config = JSON.parse(share.config); } catch { config = {}; }
  res.json({ name: share.name, config, created_at: share.created_at });
});

// landing page for share links opened in a browser
app.get('/share/:code', async (req, res) => {
  const share = await db.cols.shares.findOne({ code: req.params.code });
  if (!share) {
    return res.status(404).send('<h1>Share link expired or invalid</h1><p>Ask the creator for a new link.</p>');
  }
  const safe = String(share.name).replace(/[<>&"']/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&#39;'}[c]));
  res.send(`<!doctype html><html><head><meta charset="utf-8"><title>${safe} — CreatorPlaza Bots</title>
<style>body{font-family:sans-serif;background:#1e1f22;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.card{background:#2b2d31;padding:32px;border-radius:12px;text-align:center;max-width:420px}
a{display:inline-block;margin-top:16px;background:#5865f2;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none}</style></head>
<body><div class="card"><h2>🤖 ${safe}</h2><p>This Discord bot config is shared via CreatorPlaza Bots.</p>
<p>Import it in the app to customize and deploy your own copy.</p>
<a href="/api/share/${req.params.code}">View config JSON</a></div></body></html>`);
});

// ---------- admin ----------
app.get('/api/admin/stats', requireAdmin, async (req, res) => {
  const [users, bots, onlineBots, shares, premiumUsers, suspendedUsers] = await Promise.all([
    db.cols.users.countDocuments(),
    db.cols.bots.countDocuments(),
    db.cols.bots.countDocuments({ status: 'online' }),
    db.cols.shares.countDocuments(),
    db.cols.users.countDocuments({ plan: 'premium' }),
    db.cols.users.countDocuments({ suspended: 1 }),
  ]);
  res.json({ users, bots, onlineBots, shares, premiumUsers, suspendedUsers });
});

app.get('/api/admin/users', requireAdmin, async (req, res) => {
  const users = await db.cols.users
    .find({}, { projection: { _id: 0, password_hash: 0, salt: 0 } })
    .sort({ id: -1 }).toArray();
  for (const u of users) {
    u.bot_count = await db.cols.bots.countDocuments({ user_id: u.id });
  }
  res.json({ users });
});

app.post('/api/admin/users/:id/plan', requireAdmin, async (req, res) => {
  const plan = String(req.body?.plan || '').toLowerCase();
  if (!['free', 'premium'].includes(plan)) return res.status(400).json({ error: 'plan must be free or premium' });
  const r = await db.cols.users.updateOne({ id: Number(req.params.id) }, { $set: { plan } });
  if (!r.matchedCount) return res.status(404).json({ error: 'User not found' });
  res.json({ ok: true, user: await userRow(req.params.id) });
});

app.post('/api/admin/users/:id/role', requireAdmin, async (req, res) => {
  const role = String(req.body?.role || '').toLowerCase();
  if (!['user', 'admin'].includes(role)) return res.status(400).json({ error: 'role must be user or admin' });
  const r = await db.cols.users.updateOne({ id: Number(req.params.id) }, { $set: { role } });
  if (!r.matchedCount) return res.status(404).json({ error: 'User not found' });
  res.json({ ok: true, user: await userRow(req.params.id) });
});

app.post('/api/admin/users/:id/suspend', requireAdmin, async (req, res) => {
  if (Number(req.params.id) === Number(req.user.id)) {
    return res.status(400).json({ error: 'Cannot suspend your own account' });
  }
  const target = await userRow(req.params.id);
  if (!target) return res.status(404).json({ error: 'User not found' });
  const suspended = !!req.body?.suspended;
  await db.cols.users.updateOne({ id: target.id }, { $set: { suspended: suspended ? 1 : 0 } });
  let stoppedBots = 0;
  if (suspended) stoppedBots = await suspendUserBots(req.params.id);
  res.json({ ok: true, suspended, stoppedBots, user: await userRow(req.params.id) });
});

app.get('/api/admin/bots', requireAdmin, async (req, res) => {
  const all = await db.cols.bots
    .find({}, { projection: { _id: 0, token: 0, config: 0 } })
    .sort({ id: -1 }).toArray();
  const owners = await db.cols.users.find({}, { projection: { id: 1, username: 1 } }).toArray();
  const ownerMap = new Map(owners.map(u => [u.id, u.username]));
  res.json({
    bots: all.map(b => ({ ...b, owner: ownerMap.get(b.user_id) || '?' })),
  });
});

// ---------- admin web page ----------
app.get('/admin', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// ---------- health ----------
app.get('/api/health', (req, res) => res.json({
  ok: true,
  service: 'CreatorPlaza Bots API',
  db: 'mongodb',
}));

db.init()
  .then(() => {
    app.listen(PORT, async () => {
      console.log(`CreatorPlaza Bots API listening on http://localhost:${PORT}`);
      console.log(`Admin page: http://localhost:${PORT}/admin`);
      console.log(`Database: mongodb (${db.cols ? 'connected' : 'n/a'})`);
      // promote env-listed admin usernames
      for (const username of ADMIN_USERNAMES) {
        await db.cols.users.updateOne({ username }, { $set: { role: 'admin' } }).catch(() => {});
      }
      // leader election + bot reconciliation
      engine.startClustering().catch(e => console.error('[cluster] startup failed:', e.message));
    });
  })
  .catch(e => {
    console.error('[db] init failed:', e.message);
    process.exit(1);
  });
