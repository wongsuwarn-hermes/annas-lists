/*
 * Anna's Lists sync primitives.
 *
 * A dependency-free UMD module. Browser use: window.AnnasSyncCore; Node use:
 * require('./sync-core.js'). All functions are pure except capability-token
 * generation, whose entropy source can be injected for deterministic tests.
 */
(function (root, factory) {
  const api = factory(root);
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.AnnasSyncCore = api;
}(typeof globalThis !== 'undefined' ? globalThis : this, function (root) {
  'use strict';

  const SCHEMA = 'annas-cloud-v1';
  const EMPTY_METADATA = () => ({ schema: SCHEMA, trips: {} });
  const ID_PATTERN = /^[A-Za-z0-9_-]+$/;

  function isId(value) {
    return typeof value === 'string' && ID_PATTERN.test(value);
  }

  function parseUrl(value, baseUrl) {
    try {
      return new URL(value, baseUrl || 'https://annas-lists.local/');
    } catch (_) {
      return null;
    }
  }

  // Returns null for all old snapshot links (#share= and #sharepack= included).
  function parseLiveLink(link, baseUrl) {
    const url = parseUrl(link, baseUrl);
    if (!url || url.hash.startsWith('#share=') || url.hash.startsWith('#sharepack=')) return null;
    const shortId = url.searchParams.get('trip');
    const fragment = new URLSearchParams(url.hash.slice(1));
    const key = fragment.get('key');
    return isId(shortId) && typeof key === 'string' && key.length > 0 ? { shortId, key } : null;
  }

  // `baseUrl` may contain existing query parameters; only `trip` is replaced.
  function buildLiveLink(options) {
    const optionsObject = options || {};
    if (!isId(optionsObject.shortId) || typeof optionsObject.key !== 'string' || !optionsObject.key) {
      throw new TypeError('A short trip id and capability key are required');
    }
    const url = parseUrl(optionsObject.baseUrl || 'https://annas-lists.local/');
    if (!url) throw new TypeError('baseUrl must be a valid URL');
    url.searchParams.set('trip', optionsObject.shortId);
    url.hash = 'key=' + encodeURIComponent(optionsObject.key);
    return url.toString();
  }

  function normaliseEntry(entry) {
    if (!entry || typeof entry !== 'object' || !isId(entry.shortId) ||
        !Number.isInteger(entry.version) || entry.version < 0) return null;
    const normalised = { shortId: entry.shortId };
    if (typeof entry.readKey === 'string' && entry.readKey) normalised.readKey = entry.readKey;
    if (typeof entry.editKey === 'string' && entry.editKey) normalised.editKey = entry.editKey;
    if (entry.owner === true) normalised.owner = true;
    normalised.version = entry.version;
    if (typeof entry.lastSynced === 'string' && entry.lastSynced) normalised.lastSynced = entry.lastSynced;
    return normalised;
  }

  // Invalid data produces a safe empty mapping, so callers never overwrite local state blindly.
  function parseCloudMetadata(raw) {
    let value = raw;
    if (typeof raw === 'string') {
      try { value = JSON.parse(raw); } catch (_) { return EMPTY_METADATA(); }
    }
    if (!value || typeof value !== 'object' || value.schema !== SCHEMA || !value.trips || typeof value.trips !== 'object') {
      return EMPTY_METADATA();
    }
    const trips = {};
    for (const localTripId of Object.keys(value.trips)) {
      if (!isId(localTripId)) continue;
      const entry = normaliseEntry(value.trips[localTripId]);
      if (entry) trips[localTripId] = entry;
    }
    return { schema: SCHEMA, trips };
  }

  function serializeCloudMetadata(metadata) {
    return JSON.stringify(parseCloudMetadata(metadata));
  }

  function defaultRandomBytes(length) {
    const crypto = root.crypto;
    if (crypto && typeof crypto.getRandomValues === 'function') {
      const bytes = new Uint8Array(length);
      crypto.getRandomValues(bytes);
      return bytes;
    }
    if (typeof require === 'function') return require('node:crypto').randomBytes(length);
    throw new Error('Secure random bytes are unavailable');
  }

  function toBase64Url(bytes) {
    let base64;
    if (typeof Buffer !== 'undefined') base64 = Buffer.from(bytes).toString('base64');
    else {
      let binary = '';
      for (let index = 0; index < bytes.length; index += 1) binary += String.fromCharCode(bytes[index]);
      base64 = btoa(binary);
    }
    return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  // 32 bytes = 256 bits. Inject `randomBytes` to make a test deterministic.
  function generateCapabilityToken(randomBytes) {
    const bytes = (randomBytes || defaultRandomBytes)(32);
    if (!bytes || typeof bytes.length !== 'number' || bytes.length < 32) {
      throw new RangeError('Capability tokens require at least 32 bytes of entropy');
    }
    return toBase64Url(bytes);
  }

  function clone(value) {
    if (Array.isArray(value)) return value.map(clone);
    if (value && typeof value === 'object') {
      const result = {};
      for (const key of Object.keys(value)) result[key] = clone(value[key]);
      return result;
    }
    return value;
  }

  function createRecoveryCopy(trip, newTripId, now) {
    if (!trip || typeof trip !== 'object') throw new TypeError('A trip is required');
    if (!isId(newTripId)) throw new TypeError('A new trip id is required');
    const date = now instanceof Date ? now : new Date(now || Date.now());
    if (Number.isNaN(date.getTime())) throw new TypeError('A valid recovery timestamp is required');
    const copy = clone(trip);
    const timestamp = date.toISOString().slice(0, 16).replace('T', ' ');
    copy.id = newTripId;
    copy.name = String(trip.name || 'Untitled trip') + ' (recovery copy ' + timestamp + ')';
    return copy;
  }

  // Deliberately returns conflict rather than resolving a competing update locally.
  function classifyCloudResponse(response, error) {
    if (error || !response || response.offline === true || response instanceof Error) return 'offline';
    if (response.status === 'saved' || response.status === 'created' || response.status === 'ok') return 'saved';
    if (response.status === 'conflict') return 'conflict';
    if (response.status === 'unauthorized' || response.status === 'readonly') return 'unauthorized';
    const status = Number(response.status);
    if (status >= 200 && status < 300) return 'saved';
    if (status === 409 || status === 412) return 'conflict';
    if (status === 401 || status === 403) return 'unauthorized';
    return 'offline';
  }

  return {
    parseLiveLink,
    buildLiveLink,
    parseCloudMetadata,
    serializeCloudMetadata,
    generateCapabilityToken,
    createRecoveryCopy,
    classifyCloudResponse
  };
}));
