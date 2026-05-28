# Architecture Summary

## Overview

`pgjsonrpc` is a pure-SQL PostgreSQL extension that implements the [JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification). There is no C code. All logic lives in `sql/pgjsonrpc.sql` under the `jsonrpc` schema, built and installed via PGXS.

---

## Components

### Schema: `jsonrpc`

All objects live in the `jsonrpc` schema. The schema is hardcoded throughout the source (see Technical Debt for implications of `relocatable = true`).

---

### `jsonrpc.methods` — Method Registry

```sql
CREATE TABLE jsonrpc.methods (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    description   TEXT NOT NULL,
    function_name TEXT NOT NULL
);
```

A lookup table mapping JSON-RPC method names to fully-qualified PostgreSQL function names. The `UNIQUE(name)` constraint creates an implicit B-tree index, making lookups O(log n).

Every registered function must have this signature:

```sql
CREATE FUNCTION some_schema.my_method(p_request JSON) RETURNS JSON
```

The function is responsible for constructing its own response via the response helpers.

---

### `jsonrpc.execute(p_request TEXT) RETURNS JSON` — Entry Point

The single public API surface. Callers pass a raw JSON string; the function returns a JSON response (or batch array). Internally it:

1. Parses `TEXT → JSON` (error → `-32700 Parse error`)
2. Detects batch vs. single request
3. Validates the request structure
4. Looks up `method` in `jsonrpc.methods`
5. Dispatches via `EXECUTE FORMAT('SELECT %s(%L)', function_name, request)`
6. Returns the method function's return value directly

---

### Response Helpers

| Function | Language | Purpose |
|---|---|---|
| `jsonrpc.success_response(p_request JSON, p_result ANYELEMENT)` | plpgsql | Wraps any value in `{"id":…,"jsonrpc":"2.0","result":…}` |
| `jsonrpc.error_response(p_request JSON, p_code INT, p_message TEXT, p_data JSON)` | plpgsql | Wraps an error in `{"id":…,"jsonrpc":"2.0","error":{…}}` |
| `jsonrpc.get_response(p_request JSON, p_jsonrpc TEXT, p_id TEXT, p_result JSON, p_code INT, p_message TEXT)` | sql | Picks success or error based on `p_result IS NULL` |

`success_response` uses the `ANYELEMENT` polymorphic type so it accepts any PostgreSQL value — integer, text, JSON, composite, etc.

---

### `jsonrpc.echo(p_request JSON) RETURNS JSON` — Bundled Method

A reference implementation that returns `params.message` as the result. Its registration row is inserted by `pgjsonrpc.sql` at install time, making it the only method available out of the box.

---

## Build System

| File | Role |
|---|---|
| `Makefile` | PGXS wrapper; drives build, install, regression tests |
| `pgjsonrpc.control` | Extension metadata: name, version (`0.0.1`), `relocatable = true` |
| `META.json` | PGXN distribution metadata; `release_status: unstable` |
| `sql/pgjsonrpc.sql` | Extension body — schema, table, functions, echo registration |
| `sql/uninstall_pgjsonrpc.sql` | Manual teardown script (not used by `DROP EXTENSION`) |

---

## Test Infrastructure

Tests live in `test/sql/*.sql` with golden output in `test/expected/*.out`. Each test file:

1. Opens a transaction (`BEGIN`)
2. Loads the extension fresh (`\i sql/pgjsonrpc.sql`)
3. Optionally creates additional test functions and registry entries
4. Runs queries
5. Rolls back (`ROLLBACK`)

This makes every test fully self-contained and idempotent. `make installcheck` runs all tests via `pg_regress` and diffs actual against expected output.

---

## CI

Two GitHub Actions workflows exist:

- `.github/workflows/makefile.yml` — runs `pg-start 15 && pg-build-test` inside the `pgxn/pgxn-tools` Docker image on push/PR to `main`. This is the real CI.
- `.github/workflows/github-actions-demo.yml` — boilerplate demo workflow that echoes strings; provides no test coverage.

---

## Extension Registration Flow

```
CREATE EXTENSION pgjsonrpc;
    └─ PostgreSQL loads sql/pgjsonrpc.sql
           ├─ Creates schema jsonrpc
           ├─ Creates table jsonrpc.methods
           ├─ Creates functions: execute, success_response, error_response, get_response, echo
           └─ INSERTs echo into jsonrpc.methods
```

Users then extend the system by:
1. Creating their own method function with signature `fn(p_request JSON) RETURNS JSON`
2. `INSERT INTO jsonrpc.methods(name, description, function_name) VALUES(...)`
