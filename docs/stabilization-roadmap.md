# Stabilization Roadmap

Goal: reach a `0.1.0` release that is spec-correct, secure, and has a clean test suite.

Items are ordered by risk: security first, then spec compliance, then correctness, then cleanup.

---

## Phase 1 — Security (block release)

### 1.1 Fix SQL injection in `function_name` dispatch

**File:** `sql/pgjsonrpc.sql` ~line 207  
**Risk:** Critical — any user with `INSERT` on `jsonrpc.methods` can execute arbitrary SQL  
**Change:** Quote `function_name` using `quote_ident` split across schema and function name, or validate against `pg_catalog.pg_proc` before dispatch.

```sql
-- Option A: split and quote
l_sql := FORMAT('SELECT %I.%I(%L)',
    split_part(l_function_name, '.', 1),
    split_part(l_function_name, '.', 2),
    l_request);

-- Option B: validate existence first
PERFORM 1 FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname || '.' || p.proname = l_function_name;
IF NOT FOUND THEN
    -- treat as method not found
END IF;
```

**Test:** Add a test that attempts to register a function name containing SQL injection characters and verifies it is rejected or safely quoted.

---

## Phase 2 — Spec Compliance

### 2.1 Preserve `id` type in responses

**File:** `sql/pgjsonrpc.sql`, `success_response` and `error_response`  
**Change:** Replace `p_request->>'id'` (text coercion) with `p_request->'id'` (JSON extraction) in `json_build_object` calls.

```sql
-- Before
'id', p_request->>'id'

-- After
'id', p_request->'id'
```

**Update expected outputs:** All `.out` files that show `"id" : "1"` for a numeric `id` will change to `"id" : 1`. Regenerate with `make installcheck`.

### 2.2 Support notifications (requests without `id`)

**File:** `sql/pgjsonrpc.sql`, `execute` function  
**Change:** Before the validation block, detect whether `id` key is absent (as opposed to `id: null`). If absent, execute the method and return `NULL` (no response).

```sql
-- Check if 'id' key is present at all (not just null)
IF NOT (l_request::jsonb ? 'id') THEN
    -- notification: execute and discard result
    IF l_function_name IS NOT NULL AND l_method_name IS NOT NULL THEN
        l_sql := FORMAT('SELECT %I.%I(%L)', ...);
        EXECUTE l_sql;
    END IF;
    RETURN NULL;
END IF;
```

**Note:** Batch notifications (items in a batch with no `id`) should also produce no element in the response array per spec.

### 2.3 Replace fragile batch detection

**File:** `sql/pgjsonrpc.sql:144`  
**Change:**

```sql
-- Before
IF(substring(regexp_replace(l_request::TEXT, '^\s+', ''), 1, 1) = '[')

-- After
IF json_typeof(l_request) = 'array'
```

---

## Phase 3 — Correctness

### 3.1 Fix O(n²) batch accumulation

**File:** `sql/pgjsonrpc.sql:159–165`  
**Change:** Accumulate responses into a PL/pgSQL array, convert to JSON once at the end.

```sql
DECLARE
    l_responses JSON[] := ARRAY[]::JSON[];
...
l_responses := array_append(l_responses, jsonrpc.execute(l_request_item::TEXT));
...
RETURN array_to_json(l_responses);
```

### 3.2 Fix `relocatable` control file setting

**File:** `pgjsonrpc.control`  
**Change:** Set `relocatable = false` since the schema name is hardcoded. This prevents misleading behavior when users attempt `CREATE EXTENSION pgjsonrpc SCHEMA other`.

### 3.3 Remove dead parameters from `get_response`

**File:** `sql/pgjsonrpc.sql:83–100`  
**Change:** Drop `p_jsonrpc TEXT` and `p_id TEXT` from the signature. Update all call sites.

### 3.4 Fix diagnostic format string in outer exception handler

**File:** `sql/pgjsonrpc.sql:218`  
**Change:**

```sql
-- Before
RAISE NOTICE 'jsonrpc.execute([%]): []', p_request;

-- After
RAISE NOTICE 'jsonrpc.execute([%]): error', p_request;
-- or remove the redundant line entirely
```

### 3.5 Fix `uninstall_pgjsonrpc.sql`

**File:** `sql/uninstall_pgjsonrpc.sql`  
**Change:** Add `DROP FUNCTION` statements for `success_response` and `error_response` with correct parameter lists, and `DROP FUNCTION jsonrpc.execute(TEXT)`. Document that `DROP EXTENSION pgjsonrpc CASCADE` is preferred.

---

## Phase 4 — Test Suite Cleanup

### 4.1 Remove duplicate query in subtract-success-001

**File:** `test/sql/subtract-success-001.sql:55–77`  
Remove the second identical `subtract(minuend:23, subtrahend:42)` invocation and regenerate the `.out` file.

### 4.2 Verify subtract-failure test intent

`subtract-failure-001.sql` and `subtract-failure-002.sql` test "method not found" behavior but do not define the subtract function. Rename them to `subtract-not-registered-001.sql` / `-002.sql` and update `Makefile`'s `TESTS` glob to keep `make installcheck` passing. (Or simply add a comment explaining the naming convention.)

### 4.3 Remove stray `doc/sessions.md`

Delete the file — it contains only a session timestamp and is not documentation.

### 4.4 Remove `github-actions-demo.yml`

**File:** `.github/workflows/github-actions-demo.yml`  
This is boilerplate that triggers on every push to any branch and provides no test value. Remove it to reduce CI noise.

---

## Phase 5 — Version Bump and Release Prep

### 5.1 Adopt version migration script convention

Create `sql/pgjsonrpc--0.0.1--0.1.0.sql` containing the DDL changes from phases 1–3 as `ALTER FUNCTION`, `DROP FUNCTION`, and `CREATE OR REPLACE FUNCTION` statements. This allows users on 0.0.1 to upgrade with `ALTER EXTENSION pgjsonrpc UPDATE TO '0.1.0'` without losing registered methods.

### 5.2 Bump version to `0.1.0`

**Files:** `pgjsonrpc.control`, `META.json`

```
default_version = '0.1.0'
"release_status": "testing"
```

### 5.3 Update README and docs

Add a "Changelog" or "Upgrade" section noting the breaking change in `id` type handling (phase 2.1) so callers can update their response parsing.

---

## Execution Order Summary

```
Phase 1  (1 item)  — security fix; should be done before any wider deployment
Phase 2  (3 items) — spec compliance; causes test output changes
Phase 3  (5 items) — correctness fixes; mostly low-risk refactors
Phase 4  (4 items) — test cleanup; no functional changes
Phase 5  (3 items) — version bookkeeping; do last
```

All phases 1–4 can be done in a single PR. Phase 5 (version bump) should be its own commit/PR so the git history clearly marks the release point.
