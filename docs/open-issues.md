# Open Issues — Post Phase 1

> Remaining known risks after the Phase 1 blocking-issue fixes.  
> References: `docs/audit/security.md` (S1–S9), `docs/audit/stabilization-roadmap.md` (P0–P3).

---

## Critical / Blocking for Production (P0)

### S3 — Method Registry Writable by Any Schema User

**Status:** Open  
**File:** `sql/pgjsonrpc.sql` — no `REVOKE`/`GRANT` after `CREATE TABLE jsonrpc.methods`

Any user with `USAGE` on the `jsonrpc` schema can `INSERT` into `jsonrpc.methods`. Combined with FIX-1 (SQL injection blocked at dispatch time), this is no longer directly exploitable for arbitrary SQL execution. However, a malicious insert can still register non-existent function names, causing `-32099` errors on dispatch.

**Required fix:**
```sql
REVOKE ALL ON jsonrpc.methods FROM PUBLIC;
GRANT SELECT ON jsonrpc.methods TO PUBLIC;
GRANT INSERT, UPDATE, DELETE ON jsonrpc.methods TO jsonrpc_admin;
```

---

## High (P1 — Before External Exposure)

### S2 — Internal State Leaked in Error Responses

**Status:** Open  
**File:** `sql/pgjsonrpc.sql:134–139, 220–228`

The `data` field in `-32700` and `-32099` responses still includes full SQLSTATE, SQLERRM, stack context, and the original request text. This information aids enumeration and may expose PII if params contain sensitive data.

FIX-3 redirected the `RAISE` statements from `NOTICE` to `LOG` (server-only), but the `data` field in the returned JSON error object was not changed.

**Required fix:** Remove the `data` field from parse-error and server-error responses; rely on server-side logging for internal details.

### S6 — No Request Size Limit

**Status:** Open  
**File:** `sql/pgjsonrpc.sql` — `jsonrpc.execute` entry point

Callers can send arbitrarily large TEXT values (up to 1 GB). A 100 MB request per connection at 100 concurrent connections can exhaust `work_mem`.

**Required fix:**
```sql
IF octet_length(p_request) > 1048576 THEN
    RETURN jsonrpc.error_response(NULL, -32600, 'Request too large', NULL);
END IF;
```

---

## Medium (P2 — Spec Compliance / Hardening)

### S7 — Notifications Not Supported

**Status:** Open  
**File:** `sql/pgjsonrpc.sql:182–186`

JSON-RPC 2.0 notifications (requests with no `id` key) must produce no response. Currently a notification to a registered method returns `-32600 Invalid Request`, and a notification to an unregistered method returns `-32601 Method not found`. This asymmetry allows method enumeration without a valid `id`.

**Required fix:** Check `NOT (l_request::jsonb ? 'id')` before method lookup; return `NULL` for notifications regardless of method existence.

### P1.3 — O(n²) Batch Accumulation Not Fully Fixed

**Status:** Open  
**File:** `sql/pgjsonrpc.sql:157–165`

The batch accumulation loop still uses JSONB concatenation (`||`), which copies the accumulated array on every iteration. For large batches this is O(n²) in total bytes copied.

**Required fix:**
```sql
DECLARE
    l_responses JSON[] := ARRAY[]::JSON[];
...
    l_responses := array_append(l_responses, jsonrpc.execute(l_request_item::TEXT));
...
RETURN array_to_json(l_responses);
```

### S9 — `jsonrpc` Version Field Not Validated

**Status:** Open  
**File:** `success_response`, `error_response`

`"jsonrpc": "1.0"` requests are processed silently. The response echoes back whatever version string was sent.

**Required fix:**
```sql
IF l_request->>'jsonrpc' IS DISTINCT FROM '2.0' THEN
    RETURN jsonrpc.error_response(l_request, -32600, 'Invalid Request', NULL);
END IF;
```

---

## Low (P3 — Hardening)

### S5 — No Guard Against SECURITY DEFINER Functions

**Status:** Open

Nothing at registration time prevents pointing a method at a `SECURITY DEFINER` function. If such a function exists and a user can insert into `jsonrpc.methods` (see S3), they can escalate to the definer's privileges.

Blocked by S3 fix: once write access to `jsonrpc.methods` is restricted, this attack vector requires elevated access to exploit.

**Required fix:** Validate `pg_proc.prosecdef = false` at registration time.

### S8 — Method Name Reflected in "Not Found" Error

**Status:** Open  
**File:** `sql/pgjsonrpc.sql:190–195`

The caller-supplied method name is echoed in the error `data` field, confirming the string was received and parsed — useful for fuzzing.

**Required fix:** Return a generic `"Method not found"` with no `data` field.

### P0.4 — `relocatable = true` in Control File

**Status:** Open  
**File:** `pgjsonrpc.control`

The schema name `jsonrpc` is hardcoded throughout; `relocatable = true` is incorrect and misleading.

**Required fix:** Set `relocatable = false`.

---

## Deferred to Later Phases

| Item | Phase | Notes |
|------|-------|-------|
| SAVEPOINT-per-batch-item transaction semantics | P2.6 | Document current shared-transaction behavior first |
| Auth contract (`jsonrpc.user_id` session context) | P3.1 | Requires HTTP proxy layer |
| HTTP proxy layer | P3.2 | PostgREST or thin Go/Node server |
| Method versioning (`method@version` dispatch) | P3.3 | Requires `version` column in `jsonrpc.methods` |
| SDK generation tooling | P3.4 | External tool; introspects `pg_catalog.pg_proc` |
| Observability hooks (`jsonrpc.audit_log`) | P2.5 | Zero-config baseline: `pg_stat_user_functions` |
| Function existence validation at registration | P2.2 | Combine with P2.1 SECURITY DEFINER guard |
