import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";

const config = JSON.parse(fs.readFileSync(new URL("../config/public-config.json", import.meta.url)));
const token = () => crypto.randomBytes(32).toString("base64url");
const readToken = token();
const editToken = token();

async function rpc(name, body) {
  const response = await fetch(`${config.url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: config.publishableKey,
      authorization: `Bearer ${config.publishableKey}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { response, data };
}

const direct = await fetch(`${config.url}/rest/v1/cloud_trips?select=id&limit=1`, {
  headers: {
    apikey: config.publishableKey,
    authorization: `Bearer ${config.publishableKey}`
  }
});
assert.ok([401, 403].includes(direct.status), `direct table access returned ${direct.status}`);

const invalidPayload = await rpc("create_cloud_trip", {
  p_data: [],
  p_read_token: token(),
  p_edit_token: token()
});
assert.equal(invalidPayload.response.status, 400, JSON.stringify(invalidPayload.data));

const oversizedToken = await rpc("create_cloud_trip", {
  p_data: { name: "must not save" },
  p_read_token: "x".repeat(257),
  p_edit_token: token()
});
assert.equal(oversizedToken.response.status, 400, JSON.stringify(oversizedToken.data));

const payload = { id: `hosted-${Date.now()}`, name: "Hosted RPC verification", groups: [] };
const created = await rpc("create_cloud_trip", {
  p_data: payload,
  p_read_token: readToken,
  p_edit_token: editToken
});
assert.equal(created.response.status, 200, JSON.stringify(created.data));
assert.equal(created.data.status, "created");
assert.equal(created.data.version, 1);
assert.ok(created.data.short_id);
assert.equal(JSON.stringify(created.data).includes(readToken), false);
assert.equal(JSON.stringify(created.data).includes(editToken), false);

const shortId = created.data.short_id;
const read = await rpc("read_cloud_trip", { p_short_id: shortId, p_token: readToken });
assert.equal(read.response.status, 200, JSON.stringify(read.data));
assert.equal(read.data.payload.name, payload.name);
assert.equal(read.data.can_edit, false);

const denied = await rpc("write_cloud_trip", {
  p_short_id: shortId,
  p_edit_token: readToken,
  p_expected_version: 1,
  p_data: { ...payload, name: "must not save" }
});
assert.ok([401, 403].includes(denied.response.status), JSON.stringify(denied.data));

const saved = await rpc("write_cloud_trip", {
  p_short_id: shortId,
  p_edit_token: editToken,
  p_expected_version: 1,
  p_data: { ...payload, name: "Edited on device A" }
});
assert.equal(saved.response.status, 200, JSON.stringify(saved.data));
assert.equal(saved.data.status, "saved");
assert.equal(saved.data.version, 2);

const conflict = await rpc("write_cloud_trip", {
  p_short_id: shortId,
  p_edit_token: editToken,
  p_expected_version: 1,
  p_data: { ...payload, name: "Stale device B" }
});
assert.equal(conflict.response.status, 200, JSON.stringify(conflict.data));
assert.equal(conflict.data.status, "conflict");
assert.equal(conflict.data.version, 2);
assert.equal(conflict.data.payload.name, "Edited on device A");

console.log(JSON.stringify({
  status: "PASS",
  project: new URL(config.url).hostname,
  directTableDenied: true,
  invalidInputsDenied: true,
  create: true,
  readOnlyDenied: true,
  versionedSave: true,
  staleWritePreserved: true
}));
