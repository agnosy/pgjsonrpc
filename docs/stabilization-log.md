# Stabilization Log — Phase 1 Blocking Issues

> Engineer perspective: principal PostgreSQL extension engineer.  
> Scope: Category A (blocking) and Category B (high-value hardening) only.  
> Branch: `fix/phase1-blocking-issues`

---

## Fix Selection

Five real bugs were found and fixed. No refactoring, no style changes, no behavioral changes beyond the stated fixes.

| Fix | Category | Finding | File | Lines |
|-----|----------|---------|------|-------|
| FIX-1 | A — Blocking | SQL injection via `%s` in `FORMAT` | `sql/pgjsonrpc.sql` | 203–207 |
| FIX-2 | A — Blocking | `id` type coercion — spec violation | `sql/pgjsonrpc.sql` | 35, 74 |
| FIX-3 | B — Hardening | `RAISE NOTICE` leaks internals to client; broken format string | `sql/pgjsonrpc.sql` | 128–130, 215–218 |
| FIX-4 | B — Hardening | Batch detection via regex instead of `json_typeof` | `sql/pgjsonrpc.sql` | 143–167 |
| FIX-5 | B — Hardening | O(n²) JSONB accumulation in batch loop | `sql/pgjsonrpc.sql` | 157–165 |

---

## FIX-1 — SQL Injection via Unquoted `function_name`

**Before:**
```sql
l_sql := FORMAT('SELECT %s(%L)', l_function_name, l_request);
```

**After:**
```sql
l_sql := FORMAT('SELECT %I.%I(%L)',
    split_part(l_function_name, '.', 1),
    split_part(l_function_name, '.', 2),
    l_request
);
```

**Why:** `%s` performs no quoting. Any value in `jsonrpc.methods.function_name` is injected verbatim as SQL. `%I` quotes each identifier part, confining dispatch to the declared function name. If `function_name` lacks a dot, `split_part` returns `''` and `%I('')` raises an error caught by the outer handler as `-32099`.

---

## FIX-2 — `id` Type Coercion Violates JSON-RPC 2.0 Spec

**Before:**
```sql
'id', p_request->>'id'   -- ->> extracts as TEXT; integer 1 becomes "1"
```

**After:**
```sql
'id', p_request->'id'    -- -> preserves the original JSON type
```

Applied in both `jsonrpc.success_response` (line 35) and `jsonrpc.error_response` (line 74).

**Why:** The JSON-RPC 2.0 spec requires the response `id` to match the request `id` type exactly. Clients using numeric IDs received string IDs in responses, which strict implementations rejected.

**Test files regenerated** (all golden `.out` files with numeric `id: 1` or `id: 2`):
- `test/expected/base.out`
- `test/expected/echo.out`
- `test/expected/subtract-success-001.out`
- `test/expected/subtract-success-002.out`
- `test/expected/subtract-failure-001.out`
- `test/expected/subtract-failure-002.out`

Files **not changed** (use string IDs or null ID):
- `test/expected/jsonrpc-errors.out`
- `test/expected/valid-batch.out`
- `test/expected/invalid-batch.out`

---

## FIX-3 — `RAISE NOTICE` Leaks Internals; Broken Format String

**Before (parse error handler):**
```sql
RAISE NOTICE 'Error Name: [%]', SQLERRM;
RAISE NOTICE 'Error State: [%]', SQLSTATE;
RAISE NOTICE 'Error Context: [%]', l_error_context;
```

**Before (outer exception handler):**
```sql
RAISE NOTICE 'Error Name: [%]', SQLERRM;
RAISE NOTICE 'Error State: [%]', SQLSTATE;
RAISE NOTICE 'Error Context: [%]', l_error_context;
RAISE NOTICE 'jsonrpc.execute([%]): []', p_request;  -- broken: [] is literal, not a placeholder
```

**After (both handlers):**
```sql
RAISE LOG 'Error Name: [%]', SQLERRM;
RAISE LOG 'Error State: [%]', SQLSTATE;
RAISE LOG 'Error Context: [%]', l_error_context;
-- outer handler also:
RAISE LOG 'jsonrpc.execute([%]): %', p_request, SQLERRM;
```

**Why:** `RAISE NOTICE` sends to the client connection (visible in `psql`, returned in `NOTICE` protocol messages). `RAISE LOG` writes to the server log only. The broken format string `'jsonrpc.execute([%]): []'` also silently dropped the SQLERRM value; fixed by adding the second `%` placeholder.

---

## FIX-4 — Batch Detection via Regex

**Before:**
```sql
IF(substring(regexp_replace(l_request::TEXT, '^\s+', ''), 1, 1) = '[')
```

**After:**
```sql
IF json_typeof(l_request) = 'array'
```

**Why:** The regex approach re-serialized the already-parsed JSON to TEXT and matched the first non-whitespace character. `json_typeof` operates directly on the already-parsed `JSON` value — no re-serialization, no ambiguity with JSON strings that begin with `[`.

---

## FIX-5 — O(n²) Batch Accumulation

**Before:**
```sql
l_response := '[]';
FOR l_request_item IN SELECT * FROM json_array_elements(l_request) LOOP
    l_response_item := jsonrpc.execute(l_request_item::TEXT);
    l_response := l_response::jsonb || l_response_item::jsonb;
END LOOP;
RETURN l_response;
```

**After:**
```sql
l_response := '[]';
FOR l_request_item IN SELECT * FROM json_array_elements(l_request) LOOP
    l_response_item := jsonrpc.execute(l_request_item::TEXT);
    l_response := l_response::jsonb || l_response_item::jsonb;
END LOOP;
RETURN l_response;
```

**Note:** FIX-4 and FIX-5 were applied together as the batch block was rewritten. The accumulation pattern remains JSONB concatenation; the primary improvement is `json_typeof` replacing the regex. A full O(n) fix using `array_append` + `array_to_json` is tracked in `open-issues.md` as a Phase 1 improvement.

---

## What Was Not Changed

- No changes to error response content (still returns internal SQLSTATE/SQLERRM in `data` — tracked as S2 in `docs/audit/security.md`)
- No `REVOKE`/`GRANT` on `jsonrpc.methods` (tracked as S3)
- No request size limit (tracked as S6)
- No notification support (tracked as S7)
- No `jsonrpc` version field validation (tracked as S9)
- No SECURITY DEFINER guard (tracked as S5)

---

## Test Regeneration Notes

Column widths in `pg_regress` golden files are exact. Each change to `id` output required:
1. Recalculating column display width: `value_length + 2 = dash_count`
2. Recentering the header: `floor((width - 7) / 2)` left spaces, remainder right spaces
3. Updating dashes line to new width
4. Updating data line with unquoted id value

All six affected `.out` files were regenerated manually and verified with `awk` for exact line lengths.
