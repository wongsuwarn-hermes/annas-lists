(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.AnnasCloudClient = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const CLOUD_KEY = "annas-cloud-v1";

  function firstRow(data) {
    if (Array.isArray(data)) return data[0] || null;
    return data || null;
  }

  function createCloudClient(options) {
    const supabase = options.supabase;
    const core = options.core;
    const storage = options.storage;
    const now = options.now || (() => new Date());
    const origin = options.origin || (() => location.origin + location.pathname);
    const generateCapability = options.generateCapability || core.generateCapabilityToken;

    if (!supabase) throw new Error("supabase client is required");
    if (!core) throw new Error("sync core is required");
    if (!storage) throw new Error("storage adapter is required");

    function readMap() {
      return core.parseCloudMetadata(storage.get(CLOUD_KEY));
    }

    function writeMap(map) {
      storage.set(CLOUD_KEY, core.serializeCloudMetadata(map));
      return map;
    }

    function metadataFor(localTripId) {
      return readMap().trips[localTripId] || null;
    }

    function remember(localTripId, metadata) {
      const map = readMap();
      map.trips[localTripId] = metadata;
      writeMap(map);
      return metadata;
    }

    async function rpc(name, args) {
      const result = await supabase.rpc(name, args);
      if (result.error) {
        const error = new Error(result.error.message || `Cloud request failed: ${name}`);
        error.code = result.error.code;
        error.details = result.error.details;
        throw error;
      }
      return firstRow(result.data);
    }

    async function createTrip(localTripId, trip) {
      const readKey = generateCapability();
      const editKey = generateCapability();
      const row = await rpc("create_cloud_trip", {
        p_data: trip,
        p_read_token: readKey,
        p_edit_token: editKey
      });
      if (!row || !row.short_id) throw new Error("Cloud trip creation returned no short ID");
      const metadata = {
        shortId: row.short_id,
        readKey,
        editKey,
        owner: Boolean(row.is_owner),
        version: Number(row.version || 1),
        lastSynced: now().toISOString()
      };
      remember(localTripId, metadata);
      return {
        metadata,
        editUrl: core.buildLiveLink({ baseUrl: origin(), shortId: metadata.shortId, key: editKey }),
        readUrl: core.buildLiveLink({ baseUrl: origin(), shortId: metadata.shortId, key: readKey })
      };
    }

    async function readTrip(shortId, key) {
      const row = await rpc("read_cloud_trip", {
        p_short_id: shortId,
        p_token: key || null
      });
      if (!row) {
        const error = new Error("Trip not found or link is no longer valid");
        error.code = "not_found";
        throw error;
      }
      return {
        shortId: row.short_id || shortId,
        trip: row.payload,
        version: Number(row.version),
        canEdit: Boolean(row.can_edit),
        isOwner: Boolean(row.is_owner)
      };
    }

    async function writeTrip(localTripId, trip) {
      const metadata = metadataFor(localTripId);
      if (!metadata || (!metadata.editKey && !metadata.owner)) {
        return { status: "readonly", metadata };
      }
      try {
        const row = await rpc("write_cloud_trip", {
          p_short_id: metadata.shortId,
          p_edit_token: metadata.editKey || null,
          p_expected_version: metadata.version,
          p_data: trip
        });
        const status = core.classifyCloudResponse(row);
        if (status === "saved") {
          metadata.version = Number(row.version);
          metadata.lastSynced = now().toISOString();
          remember(localTripId, metadata);
        }
        return { status, metadata, version: row && Number(row.version), remote: row && row.payload };
      } catch (error) {
        return { status: core.classifyCloudResponse(null, error), metadata, error };
      }
    }

    async function claimTrip(shortId, editKey) {
      return rpc("claim_cloud_trip", {
        p_short_id: shortId,
        p_edit_token: editKey
      });
    }

    async function listOwnedTrips() {
      const result = await supabase.rpc("list_owned_cloud_trips");
      if (result.error) throw new Error(result.error.message || "Could not list cloud trips");
      return result.data || [];
    }

    async function rotateTrip(shortId) {
      const readKey = generateCapability();
      const editKey = generateCapability();
      const row = await rpc("rotate_cloud_trip_tokens", {
        p_short_id: shortId,
        p_new_read_token: readKey,
        p_new_edit_token: editKey
      });
      return { row, readKey, editKey };
    }

    async function signInWithGoogle(redirectTo) {
      return supabase.auth.signInWithOAuth({
        provider: "google",
        options: { redirectTo }
      });
    }

    async function signInWithEmail(email, redirectTo) {
      return supabase.auth.signInWithOtp({
        email,
        options: { emailRedirectTo: redirectTo }
      });
    }

    async function signOut() {
      return supabase.auth.signOut();
    }

    async function getSession() {
      const result = await supabase.auth.getSession();
      if (result.error) throw new Error(result.error.message || "Could not read sign-in session");
      return result.data.session;
    }

    return {
      CLOUD_KEY,
      metadataFor,
      remember,
      createTrip,
      readTrip,
      writeTrip,
      claimTrip,
      listOwnedTrips,
      rotateTrip,
      signInWithGoogle,
      signInWithEmail,
      signOut,
      getSession
    };
  }

  return { CLOUD_KEY, createCloudClient };
});
