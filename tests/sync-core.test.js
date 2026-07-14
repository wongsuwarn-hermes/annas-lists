'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Sync = require('../src/sync-core.js');

test('parses only live trip links with a capability key', () => {
  assert.deepEqual(
    Sync.parseLiveLink('https://annaslists.example/list?trip=camp_2026-A#key=readKey-123'),
    { shortId: 'camp_2026-A', key: 'readKey-123' }
  );
  assert.deepEqual(
    Sync.parseLiveLink('?trip=short-id#key=capability', 'https://annaslists.example/list'),
    { shortId: 'short-id', key: 'capability' }
  );
  assert.equal(Sync.parseLiveLink('?trip=short-id'), null);
  assert.equal(Sync.parseLiveLink('?trip=short-id#share=legacy-snapshot'), null);
  assert.equal(Sync.parseLiveLink('#share=legacy-snapshot'), null);
  assert.equal(Sync.parseLiveLink('#sharepack=legacy-pack'), null);
});

test('builds live links with the capability in the fragment, never the query', () => {
  const link = Sync.buildLiveLink({
    baseUrl: 'https://annaslists.example/app?theme=dark',
    shortId: 'camp_2026-A',
    key: 'editKey-123'
  });

  assert.equal(link, 'https://annaslists.example/app?theme=dark&trip=camp_2026-A#key=editKey-123');
  assert.deepEqual(Sync.parseLiveLink(link), { shortId: 'camp_2026-A', key: 'editKey-123' });
});

test('parses and serializes only safe annas-cloud-v1 metadata entries', () => {
  const raw = JSON.stringify({
    schema: 'annas-cloud-v1',
    trips: {
      localA: { shortId: 'short-A', readKey: 'read-A', editKey: 'edit-A', owner: true, version: 4, lastSynced: '2026-07-14T10:20:30.000Z' },
      invalid: { shortId: '', version: 3 },
      wrongVersion: { shortId: 'short-B', version: -1 }
    },
    extra: 'ignored'
  });
  const metadata = Sync.parseCloudMetadata(raw);

  assert.deepEqual(metadata, {
    schema: 'annas-cloud-v1',
    trips: {
      localA: { shortId: 'short-A', readKey: 'read-A', editKey: 'edit-A', owner: true, version: 4, lastSynced: '2026-07-14T10:20:30.000Z' }
    }
  });
  assert.deepEqual(Sync.parseCloudMetadata(Sync.serializeCloudMetadata(metadata)), metadata);
  assert.deepEqual(Sync.parseCloudMetadata('{bad json'), { schema: 'annas-cloud-v1', trips: {} });
  assert.equal(Sync.serializeCloudMetadata({ schema: 'not-cloud', trips: {} }), '{"schema":"annas-cloud-v1","trips":{}}');
});

test('generates URL-safe capability tokens from at least 256 bits of injected entropy', () => {
  const token = Sync.generateCapabilityToken(() => Uint8Array.from({ length: 32 }, (_, i) => i));
  assert.match(token, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(token, 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8');
  assert.throws(() => Sync.generateCapabilityToken(() => new Uint8Array(31)), /at least 32 bytes/);
});

test('creates a non-mutating recovery copy preserving nested trip and pack semantics', () => {
  const trip = {
    id: 'trip-old', name: 'Weekend camping', groups: [{ id: 'group-1', packs: ['anna'], items: [{ name: 'Torch', status: 'tomorrow', src: 'anna' }] }],
    communal: [{ name: 'Gas', claimedBy: 'group-1' }], pantry: [{ name: 'Tea', claimedBy: null }]
  };
  const copy = Sync.createRecoveryCopy(trip, 'trip-recovery', new Date('2026-07-14T10:20:30Z'));

  assert.equal(copy.id, 'trip-recovery');
  assert.match(copy.name, /^Weekend camping \(recovery copy 2026-07-14 10:20\)$/);
  assert.deepEqual(copy.groups[0].items[0], { name: 'Torch', status: 'tomorrow', src: 'anna' });
  assert.deepEqual(copy.groups[0].packs, ['anna']);
  copy.groups[0].items[0].status = 'packed';
  assert.equal(trip.groups[0].items[0].status, 'tomorrow');
  assert.equal(trip.id, 'trip-old');
  assert.equal(trip.name, 'Weekend camping');
});

test('classifies save responses without choosing last-write-wins', () => {
  assert.equal(Sync.classifyCloudResponse({ status: 'saved' }), 'saved');
  assert.equal(Sync.classifyCloudResponse({ status: 'conflict' }), 'conflict');
  assert.equal(Sync.classifyCloudResponse({ status: 200 }), 'saved');
  assert.equal(Sync.classifyCloudResponse({ status: 409 }), 'conflict');
  assert.equal(Sync.classifyCloudResponse({ status: 412 }), 'conflict');
  assert.equal(Sync.classifyCloudResponse({ status: 401 }), 'unauthorized');
  assert.equal(Sync.classifyCloudResponse({ status: 403 }), 'unauthorized');
  assert.equal(Sync.classifyCloudResponse({ offline: true }), 'offline');
  assert.equal(Sync.classifyCloudResponse(null), 'offline');
  assert.equal(Sync.classifyCloudResponse({ status: 500 }), 'offline');
  assert.equal(Sync.classifyCloudResponse({ status: 'saved' }, new Error('network')), 'offline');
});
