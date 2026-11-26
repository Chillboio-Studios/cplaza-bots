const crypto = require('crypto');
const db = require('./db');

const SESSION_TTL = 7 * 24 * 60 * 60 * 1000; // 7 days

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString('hex');
}

async function register(username, password) {
  username = String(username || '').trim().toLowerCase();
  if (username.length < 3 || username.length > 32 || !/^[a-z0-9_]+$/.test(username)) {
    throw new Error('Username must be 3-32 chars: letters, numbers, underscores');
  }
  if (!password || password.length < 8) throw new Error('Password must be at least 8 characters');

  const existing = await db.cols.users.findOne({ username });
  if (existing) throw new Error('Username already taken');

  const salt = crypto.randomBytes(16).toString('hex');
  const hash = hashPassword(password, salt);
  const id = await db.nextId('users');
  await db.cols.users.insertOne({
    id, username, password_hash: hash, salt,
    plan: 'free', role: 'user', suspended: 0,
    created_at: new Date(),
  });
  return id;
}

async function login(username, password) {
  const user = await db.cols.users.findOne({ username: String(username || '').trim().toLowerCase() });
  if (!user) throw new Error('Invalid username or password');
  const hash = hashPassword(String(password || ''), user.salt);
  const a = Buffer.from(hash, 'hex');
  const b = Buffer.from(user.password_hash, 'hex');
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    throw new Error('Invalid username or password');
  }
  return user;
}

async function createSession(userId) {
  const token = crypto.randomBytes(32).toString('hex');
  await db.cols.sessions.insertOne({
    token, user_id: userId, expires_at: Date.now() + SESSION_TTL,
    created_at: new Date(),
  });
  return token;
}

async function destroySession(token) {
  await db.cols.sessions.deleteOne({ token });
}

async function getSessionUser(token) {
  if (!token) return null;
  const s = await db.cols.sessions.findOne({ token, expires_at: { $gt: Date.now() } });
  if (!s) return null;
  const u = await db.cols.users.findOne({ id: s.user_id });
  return u ? { id: u.id, username: u.username } : null;
}

module.exports = { register, login, createSession, destroySession, getSessionUser };
