require('dotenv').config();
const { MongoClient } = require('mongodb');

// MongoDB is the single data backend (required for multi-replica deploys).
// MONGODB_URI may be a full connection string; the database name comes from
// the URI path, defaulting to "creatorplaza".
// Local dev: mongodb://localhost:27017 (e.g. `docker compose up mongo`).

const MONGODB_URI = process.env.MONGODB_URI || 'mongodb://localhost:27017';

let client = null;
let db = null;
let cols = null;

function dbNameFromUri(uri) {
  try {
    const path = new URL(uri).pathname.replace(/^\//, '');
    return path || 'creatorplaza';
  } catch {
    return 'creatorplaza';
  }
}

async function init() {
  client = new MongoClient(MONGODB_URI, { maxPoolSize: 10 });
  await client.connect();
  db = client.db(dbNameFromUri(MONGODB_URI));
  cols = {
    users: db.collection('users'),
    sessions: db.collection('sessions'),
    bots: db.collection('bots'),
    customBots: db.collection('custom_bots'),
    shares: db.collection('shares'),
    counters: db.collection('counters'),
    leases: db.collection('leases'),
  };
  await Promise.all([
    cols.users.createIndex({ username: 1 }, { unique: true }),
    cols.sessions.createIndex({ token: 1 }, { unique: true }),
    cols.bots.createIndex({ user_id: 1 }),
    cols.customBots.createIndex({ user_id: 1 }),
    cols.shares.createIndex({ bot_id: 1 }),
    cols.shares.createIndex({ code: 1 }, { unique: true }),
  ]);
  console.log(`[db] connected to mongodb database "${db.databaseName}"`);
}

// Numeric auto-increment IDs (keeps URLs/logic identical to the old SQL ids)
async function nextId(name) {
  const r = await cols.counters.findOneAndUpdate(
    { _id: name },
    { $inc: { seq: 1 } },
    { upsert: true, returnDocument: 'after' }
  );
  return r.seq;
}

module.exports = { init, nextId, get cols() { return cols; }, get client() { return client; } };
