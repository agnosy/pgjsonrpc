# Scalability Assessment

## Scope

`pgjsonrpc` is a dispatch layer inside PostgreSQL. It does not own connections, threads, or external state — scalability is evaluated in terms of per-call overhead, batch throughput, and concurrency characteristics within the database engine.

---

## Per-Request Overhead

Each call to `jsonrpc.execute` incurs the following fixed costs:

| Step | Cost | Notes |
|---|---|---|
| `TEXT → JSON` cast | Low | PG's native JSON parser; single pass |
| Batch detection | Trivial | Currently regex; should be `json_typeof` (see Tech Debt #3) |
| `SELECT` from `jsonrpc.methods` | Low | UNIQUE index on `name`; B-tree lookup O(log n); table will typically have < 100 rows |
| `EXECUTE FORMAT(...)` | Medium | Re-parses and re-plans the dynamic SQL on every call — no plan cache |
| Method function execution | Varies | The method itself; can be arbitrarily expensive |
| Response envelope construction | Low | `json_build_object` over a fixed set of keys |

The dominant overhead for simple methods is the `EXECUTE FORMAT` re-plan. PostgreSQL does not cache plans for `EXECUTE` inside PL/pgSQL across calls. For high-frequency simple methods, this adds measurable latency compared to a direct function call.

### Mitigation

There is no workaround within the current architecture short of changing the dispatch mechanism. Options:
- **Prepared statement cache inside plpgsql**: Not directly available for `EXECUTE`.
- **Static dispatch**: The extension could generate wrapper functions per method that call the target directly (no dynamic SQL), using the registry only for metadata.

---

## Batch Request Throughput

Batches currently process items serially in a PL/pgSQL loop:

```
n items → n recursive calls to jsonrpc.execute → n separate dispatches
```

**Allocation pattern:** JSONB response accumulation is O(n²) in bytes copied (see Tech Debt #8). At batch sizes above ~100 items this becomes the bottleneck, not method execution time.

**Concurrency:** Items are processed one at a time. The JSON-RPC 2.0 spec allows responses to be returned in any order and does not require serial execution, so parallel dispatch is spec-compliant. PostgreSQL does not offer intra-transaction parallelism in PL/pgSQL, but a C extension or `pg_background`-based approach could parallelize batch items.

**Practical guidance:** Batches of up to ~20–50 items are fine. For larger batches, callers should consider splitting requests, or the accumulation algorithm should be fixed.

---

## Concurrency

The extension holds no locks beyond what each individual query acquires. The `jsonrpc.methods` table is read-only under normal operation (populated at install time or by admins). Multiple concurrent calls to `jsonrpc.execute` do not block each other.

The `jsonrpc.methods` table uses a `SERIAL` primary key and `UNIQUE(name)`. Concurrent `INSERT` on the registry during live operation is safe but could cause transient blocking on the unique index. This is not expected to be a hot path.

---

## Memory and Resource Usage

- Per call: Two JSON values in memory (request and response), plus any allocations made by the dispatched method.
- Batch: O(n) JSON values plus the growing accumulated response. The O(n²) JSONB append means worst-case memory is proportional to `n * average_response_size²`.
- No caches, queues, or global state that accumulates across calls.

---

## Connection Scaling

The extension is stateless from a session perspective. It works correctly with connection poolers (PgBouncer in transaction mode, Odyssey, etc.) because:
- No session-level state is set or read
- No advisory locks or temporary objects are used
- Each call is a self-contained unit

---

## Bottleneck Summary

| Concern | Current Behavior | Threshold |
|---|---|---|
| Single-request latency | `EXECUTE` re-plan on every dispatch | Noticeable above ~10k req/s for trivial methods |
| Batch throughput | O(n²) JSONB accumulation | Noticeable above ~50 items/batch |
| Registry lookup | B-tree index on `name` | Not a bottleneck in practice |
| Concurrency | Fully concurrent; no shared locks | No ceiling imposed by the extension itself |
| Memory per batch | Grows quadratically with batch size | Limit large batches to < 100 items until fixed |

---

## Verdict

The extension is appropriately lightweight for its role as a thin dispatch layer. At low-to-moderate call rates (< 5k req/s) with small batches (< 20 items), there are no scalability concerns. The two concrete ceilings — `EXECUTE` re-planning and O(n²) batch accumulation — are addressable without architectural changes.
