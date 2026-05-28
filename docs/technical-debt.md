# Technical Debt Assessment

Severity ratings: **Critical** / **High** / **Medium** / **Low**

---

## 1. SQL Injection via Unquoted `function_name` — CRITICAL

**Location:** `sql/pgjsonrpc.sql:207`

```sql
l_sql := FORMAT('SELECT %s(%L)', l_function_name, l_request);
```

`%s` does not quote or escape. If an attacker can `INSERT` into `jsonrpc.methods`, they control `function_name` and can inject arbitrary SQL:

```sql
INSERT INTO jsonrpc.methods(name, description, function_name)
VALUES('evil', 'x', 'pg_sleep(10); SELECT pg_read_file(''pg_hba.conf'')--');
```

**Fix:** Use `%I` (identifier quoting) if the function is in a known schema, or split schema and function name and use `quote_ident` on each part, or validate `function_name` against `pg_catalog.pg_proc` before dispatch.

---

## 2. `id` Field Type Coercion Violates JSON-RPC 2.0 Spec — High

**Location:** `success_response`, `error_response`, `execute`

The spec requires `id` to be preserved as its original type (string, number, or null). The code uses `p_request->>'id'` (text extraction) everywhere, coercing integer IDs to strings in responses:

```json
Request:  {"id": 1, ...}
Response: {"id": "1", ...}   ← wrong; spec requires {"id": 1, ...}
```

**Fix:** Use `p_request->'id'` (JSON extraction, preserves type) in all response builders.

---

## 3. Batch Detection Uses Regex on Re-serialized JSON — Medium

**Location:** `sql/pgjsonrpc.sql:144`

```sql
IF(substring(regexp_replace(l_request::TEXT, '^\s+', ''), 1, 1) = '[')
```

At this point `l_request` is already of type `JSON` (successfully parsed). The regex strip-and-peek reimplements what the parser already knows.

**Fix:**

```sql
IF json_typeof(l_request) = 'array' THEN
```

This is more correct, avoids re-serialization, and handles edge cases like leading whitespace that the regex doesn't fully cover.

---

## 4. Notification Support Missing — Medium

**Location:** `sql/pgjsonrpc.sql:186–188`

The JSON-RPC 2.0 spec defines *notifications* as requests with no `id` field. These must not produce a response. Currently, a missing `id` returns `-32600 Invalid Request`, which is incorrect:

```json
Request:  {"jsonrpc": "2.0", "method": "echo", "params": {...}}
Expected: (no response)
Actual:   {"id": null, "jsonrpc": "2.0", "error": {"code": -32600, ...}}
```

**Fix:** Before validation, check `l_request ? 'id'` (key exists check). If the key is absent, treat as notification and return `NULL` (or skip response in batch).

---

## 5. Dead Parameters in `get_response` — Medium

**Location:** `sql/pgjsonrpc.sql:83–100`

```sql
CREATE OR REPLACE FUNCTION jsonrpc.get_response(
    p_request JSON,
    p_jsonrpc TEXT,   -- never used
    p_id      TEXT,   -- never used
    ...
)
```

`p_jsonrpc` and `p_id` are declared but not referenced anywhere in the function body. The response helpers derive these values directly from `p_request`. All call sites pass redundant values.

**Fix:** Remove `p_jsonrpc` and `p_id` from the signature.

---

## 6. `relocatable = true` Is Incorrect — Medium

**Location:** `pgjsonrpc.control`

`relocatable = true` signals that PostgreSQL can install the extension into any schema the user specifies (`CREATE EXTENSION pgjsonrpc SCHEMA myschema`). But all DDL in `pgjsonrpc.sql` hardcodes the `jsonrpc` schema:

```sql
CREATE SCHEMA IF NOT EXISTS jsonrpc;
CREATE TABLE jsonrpc.methods (...);
```

Setting `relocatable = true` without using `@extschema@` is silently wrong — the extension always installs into `jsonrpc` regardless of the user's `SCHEMA` clause.

**Fix:** Either set `relocatable = false`, or replace all `jsonrpc.` prefixes with `@extschema@.` and remove the `CREATE SCHEMA` statement.

---

## 7. `uninstall_pgjsonrpc.sql` Is Incomplete and Broken — Medium

**Location:** `sql/uninstall_pgjsonrpc.sql`

Problems:
- Missing `success_response` and `error_response` — they are never dropped.
- `DROP FUNCTION jsonrpc.get_response()` and `DROP FUNCTION jsonrpc.execute()` omit parameter lists, which will fail on PostgreSQL 14+ with overloaded functions, and is ambiguous by default.
- The file is also never invoked by `DROP EXTENSION` (which uses PostgreSQL's internal catalog); it is a manual script that callers must run themselves. Its correctness matters for any operator who installed without using `CREATE EXTENSION`.

**Note:** `DROP EXTENSION pgjsonrpc CASCADE` is the correct uninstall path for extension-managed objects. This script should either be fixed or replaced with documentation to use that.

---

## 8. O(n²) JSONB Accumulation in Batch Path — Medium

**Location:** `sql/pgjsonrpc.sql:159–165`

```sql
l_response := '[]';
FOR l_request_item IN ... LOOP
    l_response_item := jsonrpc.execute(l_request_item::TEXT);
    l_response := l_response::jsonb || l_response_item::jsonb;  -- O(n) each iteration
END LOOP;
```

Each `||` on JSONB allocates a new value by copying the growing result. For a batch of n requests the total work is O(n²) in bytes copied.

**Fix:** Collect responses into a PostgreSQL array and convert once:

```sql
l_responses := ARRAY[]::JSON[];
...
l_responses := array_append(l_responses, l_response_item);
...
RETURN array_to_json(l_responses);
```

---

## 9. Silent Exception Swallow in Batch Path — Low

**Location:** `sql/pgjsonrpc.sql:168–170`

```sql
EXCEPTION
    WHEN invalid_parameter_value THEN NULL;
```

This catch block inside the batch path silently discards `invalid_parameter_value` exceptions and falls through to the single-request path. The intent is unclear — `json_array_length` does not raise `invalid_parameter_value` for a valid JSON array. If this guard ever fires, the caller gets no response and no error indication.

**Fix:** Remove the dead exception handler or document its specific purpose.

---

## 10. Stale Diagnostic in Outer Exception Handler — Low

**Location:** `sql/pgjsonrpc.sql:218`

```sql
RAISE NOTICE 'jsonrpc.execute([%]): []', p_request;
```

The second format argument `[]` is a literal string, not a format placeholder. This line will never expand to anything useful — the notice will always read `jsonrpc.execute([<request>]): []`. The `[]` was presumably intended to be `%s` with a variable.

---

## 11. Duplicate Query in Test File — Low

**Location:** `test/sql/subtract-success-001.sql:55–77`

The same query (`subtract` with `minuend:23, subtrahend:42`) appears twice, producing identical output in `test/expected/subtract-success-001.out`. The duplication provides no additional coverage.

---

## 12. Stray File in `doc/` — Low

**Location:** `doc/sessions.md`

Contains only a session timestamp and a `claude --resume` command. Not documentation. Should be removed.

---

## 13. No Version Upgrade Path — Low

The extension is version `0.0.1` with no `sql/pgjsonrpc--0.0.1--0.0.2.sql`-style migration scripts. Any schema changes require `DROP EXTENSION` + `CREATE EXTENSION`, which destroys all registered methods. PGXS supports version migration scripts natively; this should be adopted before any breaking change is shipped.

---

## Summary Table

| # | Issue | Severity | Effort |
|---|---|---|---|
| 1 | SQL injection via `function_name` | Critical | Low |
| 2 | `id` type coercion (spec violation) | High | Low |
| 3 | Fragile batch detection regex | Medium | Trivial |
| 4 | Notification support missing | Medium | Low |
| 5 | Dead params in `get_response` | Medium | Low |
| 6 | `relocatable = true` incorrect | Medium | Low |
| 7 | Broken uninstall script | Medium | Low |
| 8 | O(n²) batch accumulation | Medium | Low |
| 9 | Silent exception swallow | Low | Trivial |
| 10 | Wrong diagnostic format string | Low | Trivial |
| 11 | Duplicate test case | Low | Trivial |
| 12 | Stray `doc/sessions.md` | Low | Trivial |
| 13 | No version upgrade path | Low | Medium |
