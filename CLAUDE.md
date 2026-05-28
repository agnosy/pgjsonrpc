# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make              # build the extension
make install      # install into PostgreSQL
make installcheck # run regression tests (requires a running PostgreSQL)
```

CI uses the `pgxn/pgxn-tools` Docker image with `pg-start 15 && pg-build-test`, which wraps the same three steps.

To run a single test file manually with `psql`:
```bash
psql -f test/sql/<name>.sql
```
(Note: this won't diff against expected output — use `make installcheck` for that.)

## Architecture

This is a pure-SQL PostgreSQL extension (no C code). All logic lives in `sql/pgjsonrpc.sql` under the `jsonrpc` schema. The build system is PGXS, driven by `pgjsonrpc.control` (version, relocatability) and `Makefile`.

### Dispatch model

`jsonrpc.execute(TEXT)` is the single entry point. It:
1. Parses the input as JSON (returns error code `-32700` on parse failure).
2. Detects batch requests (JSON arrays) and recursively calls itself for each element.
3. Looks up `p_request->>'method'` in the `jsonrpc.methods` table to find the target `function_name`.
4. Dispatches via `EXECUTE FORMAT('SELECT %s(%L)', function_name, request)`.

### Method registry

`jsonrpc.methods` maps method names to fully-qualified PostgreSQL function names. Every registered function must have this signature:

```sql
CREATE FUNCTION some_schema.my_method(p_request JSON) RETURNS JSON
```

The function is responsible for calling `jsonrpc.success_response()` or `jsonrpc.error_response()` to build its return value.

### Response helpers

- `jsonrpc.success_response(p_request JSON, p_result ANYELEMENT)` — wraps a result value.
- `jsonrpc.error_response(p_request JSON, p_code INT, p_message TEXT, p_data JSON)` — wraps an error.
- `jsonrpc.get_response(...)` — picks success or error based on whether `p_result IS NULL`.

### Standard error codes

| Code   | Meaning         |
|--------|-----------------|
| -32700 | Parse error     |
| -32600 | Invalid Request |
| -32601 | Method not found|
| -32099 | Server error    |

### Tests

Tests live in `test/sql/*.sql` with golden output in `test/expected/*.out`. Each test file loads the schema fresh inside a transaction (`\i sql/pgjsonrpc.sql`) and rolls back at the end, so tests are self-contained. When adding a test, create both the `.sql` file and the matching `.out` file.

## Development Workflow

### Trunk-based development

`main` is the trunk. All work merges back to `main` via short-lived branches — maximum lifetime is one to two days. No long-lived feature or release branches.

**Branch naming:** `<type>/<slug>` where `type` matches the conventional commit type.

```
feat/add-notifications
fix/id-type-coercion
refactor/batch-accumulation
test/subtract-edge-cases
docs/architecture-summary
ci/remove-demo-workflow
chore/bump-version-0.1.0
```

### Conventional commits

All commit messages must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:**

| Type | When to use |
|---|---|
| `feat` | New JSON-RPC method, dispatch capability, or user-facing behavior |
| `fix` | Bug fix |
| `refactor` | Code restructuring without behavior change |
| `perf` | Performance improvement |
| `test` | Test additions or changes |
| `docs` | Documentation only |
| `ci` | CI/CD workflow changes |
| `chore` | Build system, extension metadata, tooling |
| `style` | Formatting only (SQL whitespace, etc.) |
| `revert` | Reverting a prior commit |

**Scopes (optional):** `dispatch`, `batch`, `registry`, `response`, `test`, `ci`, `docs`

**Breaking changes:** append `!` before the colon — `feat(dispatch)!: change execute signature`.

**Examples:**

```
fix(response): preserve id field type from request
feat(dispatch): add notification support per spec
test(batch): add large-batch accumulation test
chore: bump version to 0.1.0
ci: remove boilerplate demo workflow
```

### Local git hook setup

Activate the commit-message validator once per clone:

```bash
git config core.hooksPath .githooks
```

The hook at `.githooks/commit-msg` validates the subject line against the conventional commit format before the commit is recorded.
