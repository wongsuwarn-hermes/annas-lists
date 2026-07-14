import json
import os
import uuid

import psycopg
from psycopg.errors import InsufficientPrivilege

password = os.environ["SUPABASE_DB_PASSWORD"]
connection = psycopg.connect(
    host="aws-1-eu-west-2.pooler.supabase.com",
    port=5432,
    dbname="postgres",
    user="postgres.dmnzxxnauzcggrfiwkaw",
    password=password,
    sslmode="require",
)
owner_id = uuid.uuid4()
other_id = uuid.uuid4()
read_token = "hosted-owner-read-" + uuid.uuid4().hex
edit_token = "hosted-owner-edit-" + uuid.uuid4().hex
new_read_token = "hosted-owner-new-read-" + uuid.uuid4().hex
new_edit_token = "hosted-owner-new-edit-" + uuid.uuid4().hex

try:
    with connection.cursor() as cursor:
        cursor.execute(
            "insert into auth.users (id, aud, role, email, encrypted_password) values (%s, 'authenticated', 'authenticated', %s, '')",
            (owner_id, f"owner-{owner_id}@example.test"),
        )
        cursor.execute(
            "insert into auth.users (id, aud, role, email, encrypted_password) values (%s, 'authenticated', 'authenticated', %s, '')",
            (other_id, f"other-{other_id}@example.test"),
        )
        cursor.execute("set local role authenticated")
        cursor.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(owner_id),))
        cursor.execute(
            "select public.create_cloud_trip(%s::jsonb, %s, %s)",
            (json.dumps({"name": "Hosted owner verification", "groups": []}), read_token, edit_token),
        )
        created = cursor.fetchone()[0]
        short_id = created["short_id"]
        assert created["is_owner"] is True

        cursor.execute("select public.read_cloud_trip(%s, null)", (short_id,))
        owner_read = cursor.fetchone()[0]
        assert owner_read["is_owner"] is True and owner_read["can_edit"] is True

        cursor.execute(
            "select public.write_cloud_trip(%s, null, %s, %s::jsonb)",
            (short_id, 1, json.dumps({"name": "Owner recovered edit", "groups": []})),
        )
        owner_write = cursor.fetchone()[0]
        assert owner_write["status"] == "saved" and owner_write["version"] == 2

        cursor.execute("select * from public.list_owned_cloud_trips() where short_id = %s", (short_id,))
        assert cursor.fetchone() is not None

        cursor.execute(
            "select public.rotate_cloud_trip_tokens(%s, %s, %s)",
            (short_id, new_read_token, new_edit_token),
        )
        assert cursor.fetchone()[0]["status"] == "rotated"

        cursor.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(other_id),))
        cursor.execute("savepoint before_steal")
        try:
            cursor.execute("select public.claim_cloud_trip(%s, %s)", (short_id, new_edit_token))
            raise AssertionError("second user stole the trip")
        except InsufficientPrivilege:
            cursor.execute("rollback to savepoint before_steal")

        cursor.execute("reset role")
        cursor.execute("set local role anon")
        cursor.execute("savepoint before_old_read")
        try:
            cursor.execute("select public.read_cloud_trip(%s, %s)", (short_id, read_token))
            raise AssertionError("old read capability remained valid")
        except InsufficientPrivilege:
            cursor.execute("rollback to savepoint before_old_read")

        cursor.execute("select public.read_cloud_trip(%s, %s)", (short_id, new_read_token))
        assert cursor.fetchone()[0]["status"] == "ok"

    print(json.dumps({
        "status": "PASS",
        "authenticatedCreateOwned": True,
        "ownerCapabilityFreeRecovery": True,
        "ownerCapabilityFreeWrite": True,
        "ownerListing": True,
        "ownerRotation": True,
        "ownershipStealingDenied": True,
        "oldCapabilityRevoked": True,
    }))
finally:
    connection.rollback()
    connection.close()
