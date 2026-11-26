const { Client, GatewayIntentBits, REST, Routes, Events } = require('discord.js');
const os = require('os');
const db = require('./db');

// Running bot instances: botId -> { client, status }
const instances = new Map();

const INTENTS = [
  GatewayIntentBits.Guilds,
  GatewayIntentBits.GuildMembers,
  GatewayIntentBits.GuildMessages,
  GatewayIntentBits.MessageContent,
  GatewayIntentBits.GuildMessageReactions,
  GatewayIntentBits.GuildModeration,
];

function interpolate(template, vars) {
  if (typeof template !== 'string') return template;
  return template.replace(/\{\{\s*(\w+)\s*\}\}/g, (_, key) => {
    const v = vars[key];
    if (v === undefined || v === null) return '';
    if (typeof v === 'object') return String(v); // User/Role/Channel toString -> mention
    return String(v);
  });
}

function buildVars(src, extra = {}) {
  const isInteraction = !!src.isCommand?.();
  const user = isInteraction ? src.user : (src.author || src.user); // GuildMember has .user
  const guild = src.guild || null;
  const channel = src.channel || guild?.systemChannel || null;
  return {
    user,
    username: user?.username,
    server: guild?.name || 'DM',
    channel: channel?.name || 'DM',
    message: isInteraction ? '' : (src.content || ''),
    args: extra.args || '',
    memberCount: guild?.memberCount || 0,
  };
}

function findRole(guild, query) {
  if (!query) return null;
  query = String(query).trim();
  const byId = guild.roles.cache.get(query.replace(/[<@&>]/g, ''));
  if (byId) return byId;
  const lower = query.toLowerCase().replace(/^@/, '');
  return guild.roles.cache.find(r => r.name.toLowerCase() === lower) || null;
}

function findChannel(guild, query) {
  if (!query) return null;
  query = String(query).trim();
  const byId = guild.channels.cache.get(query.replace(/[<#>]/g, ''));
  if (byId) return byId;
  const lower = query.toLowerCase().replace(/^#/, '');
  return guild.channels.cache.find(c => c.name?.toLowerCase() === lower) || null;
}

async function checkConditions(conditions, ctx) {
  // ctx: { guild, member, channel, interactionOrMsg, vars }
  for (const cond of conditions || []) {
    if (!cond.type) continue;
    try {
      if (cond.type === 'role') {
        const role = findRole(ctx.guild, cond.value);
        if (!role || !ctx.member?.roles.cache.has(role.id)) return false;
      } else if (cond.type === 'channel') {
        const ch = findChannel(ctx.guild, cond.value);
        if (!ch || ch.id !== ctx.channel?.id) return false;
      } else if (cond.type === 'permission') {
        const perm = cond.value;
        const perms = ctx.interactionOrMsg?.memberPermissions;
        if (perms && perm && !perms.has(perm)) return false;
      }
    } catch { /* ignore bad condition */ }
  }
  return true;
}

// Resolve moderation target: if the action names a slash-command user
// argument, fetch that member; otherwise the command invoker / event member.
async function resolveTarget(action, ctx) {
  if (ctx.isInteraction && action.targetArg && ctx.src.options) {
    // Discord option names are sanitized at registration; the editor may
    // store the raw arg name, so try both forms.
    const raw = String(action.targetArg);
    const names = [...new Set([raw, sanitizeArgName(raw)])];
    let target = null;
    for (const n of names) {
      try {
        target = ctx.src.options.getMember?.(n) ?? ctx.src.options.getUser?.(n);
      } catch { /* type mismatch etc. */ }
      if (target) break;
    }
    if (target?.id && ctx.guild?.members) {
      const m = await ctx.guild.members.fetch(target.id).catch(() => null);
      if (m) return m;
    }
    if (target) return target;
  }
  return ctx.member;
}

// Send a one-time ephemeral error reply so failures aren't silent.
async function notifyError(ctx, e) {
  if (!ctx.isInteraction || ctx._errNotified) return;
  ctx._errNotified = true;
  const msg = `Action failed: ${e?.message || 'unknown error'}`.slice(0, 1900);
  try {
    if (ctx.replied) await ctx.src.followUp({ content: msg, flags: 64 });
    else await ctx.src.reply({ content: msg, flags: 64 });
  } catch { /* interaction may be expired */ }
}

async function runActions(actions, ctx) {
  for (const action of actions || []) {
    if (!action.type) continue;
    try {
      await runAction(action, ctx);
    } catch (e) {
      console.error(`[engine] action ${action.type} failed:`, e.message);
      await notifyError(ctx, e);
    }
  }
}

async function runAction(action, ctx) {
  const { vars, interactionOrMsg: src, guild } = ctx;
  const v = (s) => interpolate(s, vars);

  switch (action.type) {
    case 'send': {
      const content = v(action.content);
      const target = action.channel ? findChannel(guild, action.channel) : ctx.channel;
      if (!content) return;
      if (ctx.isInteraction) {
        const payload = { content, allowedMentions: { parse: [] } };
        if (ctx.replied) await src.followUp(payload).catch(() => {});
        else { await src.reply(payload).catch(() => src.followUp(payload).catch(() => {})); ctx.replied = true; }
      } else {
        const ch = target || ctx.channel;
        if (ch?.isTextBased()) await ch.send({ content, allowedMentions: { parse: [] } });
      }
      break;
    }
    case 'embed': {
      const embed = { color: parseInt((action.color || '#5865F2').replace('#', ''), 16) };
      if (action.title) embed.title = v(action.title);
      if (action.description) embed.description = v(action.description);
      if (action.footer) embed.footer = { text: v(action.footer) };
      if (action.thumbnail) embed.thumbnail = { url: v(action.thumbnail) };
      const payload = { embeds: [embed], allowedMentions: { parse: [] } };
      if (ctx.isInteraction) {
        if (ctx.replied) await src.followUp(payload).catch(() => {});
        else { await src.reply(payload).catch(() => src.followUp(payload).catch(() => {})); ctx.replied = true; }
      } else {
        const ch = (action.channel ? findChannel(guild, action.channel) : null) || ctx.channel;
        if (ch?.isTextBased()) await ch.send(payload);
      }
      break;
    }
    case 'react': {
      if (action.emoji && src.react) await src.react(v(action.emoji)).catch(() => {});
      break;
    }
    case 'dm': {
      const content = v(action.content);
      if (!content) return;
      const target = vars.user;
      if (target?.send) {
        await target.send({ content, allowedMentions: { parse: [] } }).catch(() => {});
      }
      break;
    }
    case 'addrole': {
      const role = findRole(guild, action.role);
      const member = ctx.member;
      if (role && member?.roles?.add) await member.roles.add(role).catch(() => {});
      break;
    }
    case 'removerole': {
      const role = findRole(guild, action.role);
      const member = ctx.member;
      if (role && member?.roles?.remove) await member.roles.remove(role).catch(() => {});
      break;
    }
    case 'kick': {
      const member = await resolveTarget(action, ctx);
      if (!member?.kick) throw new Error('Could not resolve a member to kick');
      if (member.kickable === false) throw new Error('Cannot kick this member (permissions or role hierarchy)');
      await member.kick(v(action.reason) || 'Kicked by bot');
      break;
    }
    case 'ban': {
      const member = await resolveTarget(action, ctx);
      if (typeof member?.ban !== 'function') throw new Error('Could not resolve a member to ban');
      if (member.bannable === false) throw new Error('Cannot ban this member (permissions or role hierarchy)');
      await member.ban({ reason: v(action.reason) || 'Banned by bot' });
      break;
    }
    case 'timeout': {
      const member = await resolveTarget(action, ctx);
      if (!member?.timeout) throw new Error('Could not resolve a member to timeout');
      if (member.moderatable === false) throw new Error('Cannot timeout this member (permissions or role hierarchy)');
      const minutes = parseInt(action.minutes, 10) || 10;
      await member.timeout(minutes * 60 * 1000, v(action.reason) || 'Timed out by bot');
      break;
    }
    default:
      break;
  }
}

function makeCtx(src, extra = {}) {
  const isInteraction = !!src.isCommand?.();
  return {
    src,
    isInteraction,
    interactionOrMsg: src,
    guild: src.guild || null,
    channel: src.channel || src.guild?.systemChannel || null,
    member: src.member || (src.roles ? src : null),
    vars: { ...buildVars(src, extra), ...(extra.argVars || {}) },
    replied: false,
  };
}

async function fireModule(client, moduleDef, src, extra = {}) {
  if (!moduleDef?.enabled) return;
  const ctx = makeCtx(src, extra);
  const ok = await checkConditions(moduleDef.conditions, ctx);
  if (!ok) return;
  await runActions(moduleDef.actions, ctx);
}

function parseConfig(configJson) {
  try { return JSON.parse(configJson || '{}'); } catch { return {}; }
}

// option type names (editor) -> Discord API option types
// verified against discord.js v14 ApplicationCommandOptionType:
// String=3 Integer=4 Boolean=5 User=6 Channel=7 Role=8 Number=10
const OPT_TYPES = {
  string: 3, integer: 4, boolean: 5,
  user: 6, channel: 7, role: 8, number: 10,
};

function sanitizeArgName(name) {
  return String(name || '').toLowerCase().replace(/[^a-z0-9_-]/g, '_').replace(/^_+|_+$/g, '').slice(0, 32);
}

async function deployBot(botRow) {
  const botId = botRow.id;
  stopBot(botId);
  db.cols.bots.updateOne({ id: botId }, { $set: { status: 'connecting' } }).catch(() => {});

  const config = parseConfig(botRow.config);
  const token = (botRow.token || '').trim();
  if (!token) throw new Error('Bot token is required');

  const client = new Client({ intents: INTENTS });
  // register the instance immediately so stopBot() can destroy it even
  // before ClientReady fires (prevents deploy/stop races)
  instances.set(botId, { client, status: 'connecting' });

  const modules = (config.modules || []).filter(m => m.enabled !== false);

  // Slash command triggers -> register + handler
  const commandModules = modules.filter(m => m.trigger?.type === 'command' && m.trigger.command);
  const commands = commandModules.map(m => ({
    name: sanitizeArgName(m.trigger.command) || 'command',
    description: m.trigger.description || 'A CreatorPlaza bot command',
    options: (m.trigger.args || [])
      .map(a => ({
        name: sanitizeArgName(a.name),
        description: String(a.description || '...').slice(0, 100) || '...',
        type: OPT_TYPES[a.type] || 3,
        required: !!a.required,
      }))
      .filter(o => o.name)
      .slice(0, 25),
  }));
  // Discord rejects the whole registration on duplicate command names
  const seen = new Set();
  const uniqueCommands = commands.filter(c => !seen.has(c.name) && seen.add(c.name));

  client.once(Events.ClientReady, async (c) => {
    // guard: if this client was stopped/replaced while connecting, bail
    if (instances.get(botId)?.client !== c) return;
    instances.set(botId, { client: c, status: 'online' });
    db.cols.bots.updateOne({ id: botId }, { $set: { status: 'online' } }).catch(() => {});
    console.log(`[${c.user.tag}] online (${modules.length} modules)`);

    if (uniqueCommands.length) {
      try {
        const rest = new REST().setToken(token);
        await rest.put(Routes.applicationCommands(c.user.id), { body: uniqueCommands });
      } catch (e) {
        console.error(`[${c.user.tag}] command registration failed:`, e.message);
      }
    }

    // presence
    const p = config.settings?.presence;
    if (p?.activity) {
      const types = { playing: 0, listening: 2, watching: 3, competing: 5 };
      c.user.setPresence({
        status: p.status || 'online',
        activities: [{ name: p.activity, type: types[p.type] ?? 0 }],
      });
    }
  });

  client.on(Events.Error, (e) => console.error(`[bot ${botId}] client error:`, e.message));
  client.on(Events.Warn, (w) => console.warn(`[bot ${botId}] warn:`, w));

  // Slash commands
  for (const m of commandModules) {
    const name = sanitizeArgName(m.trigger.command);
    client.on(Events.InteractionCreate, async (interaction) => {
      if (!interaction.isChatInputCommand() || interaction.commandName !== name) return;
      // expose each option as {{option_name}} and a flat {{args}} string.
      // CommandInteractionOption carries resolved entities on .user/.member/
      // .role/.channel; .value is the raw payload (id for entities).
      const argVars = {};
      const argStrings = [];
      for (const o of interaction.options.data) {
        const opt = interaction.options.get(o.name);
        const val = opt?.member ?? opt?.user ?? opt?.role ?? opt?.channel ?? opt?.value ?? o.value;
        argVars[o.name] = val;
        argStrings.push(val == null ? '' : String(val));
      }
      try {
        await fireModule(client, m, interaction, { args: argStrings.join(' '), argVars });
      } catch (e) {
        console.error(`[bot ${botId}] command handler error:`, e.message);
        interaction.reply({ content: 'Something went wrong running this command.', flags: 64 }).catch(() => {});
      }
    });
  }

  // Message trigger
  for (const m of modules.filter(x => x.trigger?.type === 'message')) {
    const keyword = (m.trigger.keyword || '').toLowerCase();
    if (!keyword) continue;
    client.on(Events.MessageCreate, async (msg) => {
      if (msg.author?.bot) return;
      if (!msg.content?.toLowerCase().includes(keyword)) return;
      await fireModule(client, m, msg);
    });
  }

  // Member join trigger
  for (const m of modules.filter(x => x.trigger?.type === 'join')) {
    client.on(Events.GuildMemberAdd, async (member) => {
      await fireModule(client, m, member);
    });
  }

  // Reaction trigger
  for (const m of modules.filter(x => x.trigger?.type === 'reaction')) {
    const emojiFilter = (m.trigger.emoji || '').trim();
    client.on(Events.MessageReactionAdd, async (reaction, user) => {
      if (user.bot) return;
      try {
        if (emojiFilter) {
          const emoji = reaction.emoji.identifier || reaction.emoji.name;
          if (emoji !== emojiFilter) return;
        }
        // pseudo-source: fake object with guild/channel/user
        const src = {
          guild: reaction.message.guild,
          channel: reaction.message.channel,
          author: user,
          member: reaction.message.member,
          isCommand: () => false,
          react: null,
        };
        await fireModule(client, m, src);
      } catch (e) {
        console.error(`[bot ${botId}] reaction handler error:`, e.message);
      }
    });
  }

  try {
    await client.login(token);
  } catch (e) {
    if (instances.get(botId)?.client === client) instances.delete(botId);
    throw e;
  }
  return botId;
}

function stopBot(botId) {
  const inst = instances.get(botId);
  if (inst?.client) {
    inst.client.destroy();
  }
  instances.delete(botId);
}

// ---------- multi-replica clustering ----------
// Only the "leader" replica hosts Discord bots. Leadership is a Mongo lease
// document (auto-expires if the pod dies); the reconciler polls the bots
// collection and converges actual state to desired_status, so API writes on
// any replica take effect within POLL_MS.

const POLL_MS = 3000;
const FAIL_BACKOFF_MS = 60000;
const LEASE_MS = 15000;
const POD_ID = process.env.POD_NAME || `${os.hostname()}-${process.pid}`;

let isLeader = false;
let renewTimer = null;
let electTimer = null;
const deployedVersions = new Map(); // botId -> config_version running here
const failMap = new Map();          // botId -> last failed deploy timestamp

async function tryAcquireLeadership() {
  try {
    const now = Date.now();
    const res = await db.cols.leases.findOneAndUpdate(
      { _id: 'bot-leader', $or: [{ expiresAt: { $lt: now } }, { holder: POD_ID }] },
      { $set: { holder: POD_ID, expiresAt: now + LEASE_MS, pod: POD_ID } },
      { upsert: true, returnDocument: 'after' }
    );
    if (res?.holder === POD_ID) becomeLeader();
  } catch (e) {
    console.error('[cluster] leader election error:', e.message);
  }
}

async function renewLeadership() {
  try {
    const r = await db.cols.leases.updateOne(
      { _id: 'bot-leader', holder: POD_ID },
      { $set: { expiresAt: Date.now() + LEASE_MS } }
    );
    if (!r.modifiedCount && !r.matchedCount) loseLeadership();
  } catch (e) {
    console.error('[cluster] lease renew error:', e.message);
    loseLeadership();
  }
}

function becomeLeader() {
  if (isLeader) return;
  isLeader = true;
  console.log(`[cluster] ${POD_ID} is the bot leader`);
  renewTimer = setInterval(renewLeadership, LEASE_MS / 3);
  reconcile().catch(e => console.error('[cluster] reconcile error:', e.message));
  reconcileTimer = setInterval(
    () => reconcile().catch(e => console.error('[cluster] reconcile error:', e.message)),
    POLL_MS
  );
}

function loseLeadership() {
  if (!isLeader) return;
  isLeader = false;
  if (renewTimer) clearInterval(renewTimer);
  if (reconcileTimer) clearInterval(reconcileTimer);
  renewTimer = reconcileTimer = null;
  for (const id of [...instances.keys()]) stopBot(id);
  deployedVersions.clear();
  console.log('[cluster] lost bot leadership — bots stopped');
}

async function reconcile() {
  if (!isLeader) return;
  const bots = await db.cols.bots.find({}).toArray();
  const knownIds = new Set(bots.map(b => Number(b.id)));
  // stop bots whose rows were deleted (e.g. DELETE hit a different replica)
  for (const id of [...instances.keys()]) {
    if (!knownIds.has(Number(id))) {
      stopBot(id);
      deployedVersions.delete(id);
    }
  }
  for (const b of bots) {
    const desired = b.desired_status || 'offline';
    const running = instances.has(b.id);
    const versionOk = deployedVersions.get(b.id) === b.config_version;
    try {
      if (desired === 'online') {
        const backedOff = failMap.has(b.id) && Date.now() - failMap.get(b.id) < FAIL_BACKOFF_MS;
        if ((!running || !versionOk) && !backedOff) {
          await deployBot(b);
          deployedVersions.set(b.id, b.config_version);
          failMap.delete(b.id);
        }
      } else {
        failMap.delete(b.id);
        if (running) {
          stopBot(b.id);
          deployedVersions.delete(b.id);
          await db.cols.bots.updateOne({ id: b.id }, { $set: { status: 'offline' } }).catch(() => {});
        } else if (b.status && b.status !== 'offline') {
          await db.cols.bots.updateOne({ id: b.id }, { $set: { status: 'offline' } }).catch(() => {});
        }
      }
    } catch (e) {
      console.error(`[cluster] reconcile bot ${b.id} failed:`, e.message);
      failMap.set(b.id, Date.now());
      await db.cols.bots.updateOne({ id: b.id }, { $set: { status: 'error' } }).catch(() => {});
    }
  }
}

async function startClustering() {
  await tryAcquireLeadership();
  electTimer = setInterval(() => {
    if (!isLeader) tryAcquireLeadership().catch(() => {});
  }, 10000);
}

module.exports = { deployBot, stopBot, startClustering, parseConfig };
