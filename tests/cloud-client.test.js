const test = require("node:test");
const assert = require("node:assert/strict");
const { createCloudClient, CLOUD_KEY } = require("../src/cloud-client.js");
const core = require("../src/sync-core.js");

function harness(responses) {
  const calls = [];
  const values = {};
  let tokenNumber = 0;
  const supabase = {
    async rpc(name, args) {
      calls.push({ name, args });
      const answer = responses[name];
      return typeof answer === "function" ? answer(args) : answer;
    },
    auth: {
      async signInWithOAuth(args) { calls.push({ name: "oauth", args }); return { data: args, error: null }; },
      async signInWithOtp(args) { calls.push({ name: "otp", args }); return { data: args, error: null }; },
      async signOut() { calls.push({ name: "signout" }); return { error: null }; },
      async getSession() { return { data: { session: { user: { id: "u1" } } }, error: null }; }
    }
  };
  const storage = {
    get(key) { return values[key] || null; },
    set(key, value) { values[key] = value; }
  };
  const client = createCloudClient({
    supabase,
    core,
    storage,
    now: () => new Date("2026-07-14T12:00:00Z"),
    origin: () => "https://annaslists.xyz/",
    generateCapability: () => `token-${++tokenNumber}-${"x".repeat(36)}`
  });
  return { client, calls, values };
}

test("createTrip stores only cloud metadata locally and returns separate links", async () => {
  const h = harness({
    create_cloud_trip: { data: [{ short_id: "camp123", version: 1, is_owner: true }], error: null }
  });
  const trip = { id: "local1", name: "Camping" };
  const result = await h.client.createTrip("local1", trip);
  const stored = JSON.parse(h.values[CLOUD_KEY]);
  assert.equal(stored.trips.local1.shortId, "camp123");
  assert.equal(stored.trips.local1.version, 1);
  assert.equal(stored.trips.local1.owner, true);
  assert.match(result.editUrl, /#key=token-2-/);
  assert.match(result.readUrl, /#key=token-1-/);
  assert.equal(h.calls[0].args.p_data, trip);
});

test("readTrip preserves backend edit permission", async () => {
  const h = harness({
    read_cloud_trip: { data: [{ short_id: "camp123", version: 4, payload: { name: "Camping" }, can_edit: false, is_owner: false }], error: null }
  });
  const result = await h.client.readTrip("camp123", "read-secret");
  assert.deepEqual(result.trip, { name: "Camping" });
  assert.equal(result.version, 4);
  assert.equal(result.canEdit, false);
});

test("writeTrip updates version only after a saved response", async () => {
  const h = harness({
    write_cloud_trip: { data: [{ status: "saved", version: 5, payload: { name: "Camping" } }], error: null }
  });
  h.client.remember("local1", { shortId: "camp123", editKey: "secret", version: 4, lastSynced: null });
  const result = await h.client.writeTrip("local1", { id: "local1", name: "Camping" });
  assert.equal(result.status, "saved");
  assert.equal(h.client.metadataFor("local1").version, 5);
});

test("writeTrip exposes conflict without advancing local version", async () => {
  const h = harness({
    write_cloud_trip: { data: [{ status: "conflict", version: 7, payload: { name: "Remote" } }], error: null }
  });
  h.client.remember("local1", { shortId: "camp123", editKey: "secret", version: 4, lastSynced: null });
  const result = await h.client.writeTrip("local1", { name: "Local" });
  assert.equal(result.status, "conflict");
  assert.equal(result.version, 7);
  assert.deepEqual(result.remote, { name: "Remote" });
  assert.equal(h.client.metadataFor("local1").version, 4);
});

test("writeTrip is read-only without an edit capability", async () => {
  const h = harness({});
  h.client.remember("local1", { shortId: "camp123", readKey: "reader", version: 2 });
  const result = await h.client.writeTrip("local1", { name: "Local" });
  assert.equal(result.status, "readonly");
  assert.equal(h.calls.length, 0);
});

test("an authenticated owner can read and write without recovering an old capability", async () => {
  const h = harness({
    read_cloud_trip: { data: [{ short_id: "camp123", version: 4, payload: { name: "Camping" }, can_edit: true, is_owner: true }], error: null },
    write_cloud_trip: { data: [{ status: "saved", version: 5, payload: { name: "Owner edit" } }], error: null }
  });
  h.client.remember("local1", { shortId: "camp123", owner: true, version: 4, lastSynced: null });
  const read = await h.client.readTrip("camp123", null);
  const written = await h.client.writeTrip("local1", { name: "Owner edit" });
  assert.equal(read.isOwner, true);
  assert.equal(written.status, "saved");
  assert.equal(h.calls[0].args.p_token, null);
  assert.equal(h.calls[1].args.p_edit_token, null);
});

test("an owner can rotate both live-link capabilities without exposing hashes", async () => {
  const h = harness({
    rotate_cloud_trip_tokens: { data: [{ status: "rotated", version: 4 }], error: null }
  });
  const result = await h.client.rotateTrip("camp123");
  assert.equal(result.row.status, "rotated");
  assert.notEqual(result.readKey, result.editKey);
  assert.equal(h.calls[0].args.p_short_id, "camp123");
  assert.equal(h.calls[0].args.p_new_read_token, result.readKey);
  assert.equal(h.calls[0].args.p_new_edit_token, result.editKey);
  assert.equal("read_token_hash" in result.row, false);
});

test("optional auth uses Google OAuth or email magic links and never passwords", async () => {
  const h = harness({});
  await h.client.signInWithGoogle("https://annaslists.xyz/");
  await h.client.signInWithEmail("simon@example.com", "https://annaslists.xyz/");
  assert.equal(h.calls[0].name, "oauth");
  assert.equal(h.calls[0].args.provider, "google");
  assert.equal(h.calls[1].name, "otp");
  assert.equal(h.calls[1].args.email, "simon@example.com");
  assert.equal("password" in h.calls[1].args, false);
});
