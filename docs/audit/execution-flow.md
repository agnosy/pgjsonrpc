# Execution Flow — Deep Audit

> Complete lifecycle trace with Mermaid diagrams.  
> See `docs/execution-flow.md` for the concise reference version.

---

## 1. Single Request Lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant Caller
    participant execute as jsonrpc.execute()
    participant registry as jsonrpc.methods
    participant method as Method Function

    Caller->>execute: TEXT request

    note over execute: Inner block — JSON parse
    alt JSON parse failure
        execute-->>Caller: {"error":{"code":-32700,"message":"Parse error","data":[SQLSTATE,SQLERRM,context]}}
    end

    note over execute: Batch detection<br/>re-serializes JSON → TEXT, strips whitespace, checks char[0]<br/>⚠ Should use json_typeof(l_request) = 'array'
    alt Starts with '['
        execute->>execute: → Batch path (diagram 2)
    end

    note over execute: Field extraction
    execute->>execute: l_id := request->>'id'<br/>l_jsonrpc := request->>'jsonrpc'<br/>l_method_name := request->>'method'

    execute->>registry: SELECT function_name FROM jsonrpc.methods WHERE name = l_method_name
    registry-->>execute: function_name OR NULL

    alt l_method_name IS NULL
        execute-->>Caller: {"error":{"code":-32600,"message":"Invalid Request"}}
    else l_id IS NULL
        execute-->>Caller: {"error":{"code":-32600,"message":"Invalid Request"}}
        note over execute: ⚠ Spec: absent 'id' = notification (no response)<br/>IS NULL catches both absent and explicit null
    else function_name IS NULL
        execute-->>Caller: {"error":{"code":-32601,"message":"Method not found","data":"Function corresponding to method(...) not found"}}
        note over execute: ⚠ Leaks method name in error data
    end

    note over execute: Dynamic dispatch<br/>FORMAT('SELECT %s(%L)', function_name, request)<br/>⚠ function_name uses %s — no identifier quoting
    execute->>method: EXECUTE sql INTO l_response

    method-->>execute: JSON (via success_response or error_response)
    execute-->>Caller: l_response

    note over execute: Outer EXCEPTION WHEN OTHERS
    alt Unhandled exception
        execute-->>Caller: {"error":{"code":-32099,"message":"Exception in jsonrpc.execute(...)","data":[request,SQLSTATE,SQLERRM,context]}}
        note over execute: ⚠ Leaks full request + internal error state to caller
    end
```

---

## 2. Batch Request Lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant Caller
    participant execute as jsonrpc.execute()
    participant self as jsonrpc.execute() [recursive]

    Caller->>execute: '[{req1}, {req2}, {req3}]'

    note over execute: JSON parse (same as single)

    note over execute: Detect array — enter batch block
    alt json_array_length = 0
        execute-->>Caller: {"error":{"code":-32600,"message":"Invalid Request"}}
    end

    note over execute: l_response := '[]'::JSON

    loop json_array_elements(l_request)
        execute->>self: jsonrpc.execute(element::TEXT)
        self-->>execute: response_item JSON
        note over execute: l_response := l_response::jsonb || response_item::jsonb<br/>⚠ O(n²) — copies entire accumulated result each iteration
    end

    execute-->>Caller: '[{resp1},{resp2},{resp3}]'

    note over execute: ⚠ All items share caller's transaction.<br/>Spec says items are independent — this is a semantic divergence.
```

---

## 3. Dynamic Dispatch Internals

```mermaid
flowchart LR
    A["l_function_name\n(from jsonrpc.methods)"]
    A --> B["FORMAT('SELECT %s(%L)',\n  l_function_name,\n  l_request::TEXT)"]
    B --> C["Raw SQL string\ne.g. SELECT jsonrpc.echo('...')"]
    C --> D["EXECUTE l_sql INTO l_response\n(re-planned every call — no cache)"]
    D --> E["l_response: JSON"]

    A -. "⚠ %s = unquoted\nSQL injection if\njsonrpc.methods writable" .-> B
    A -. "✓ %L = pg_escape_literal\nrequest arg is safe" .-> B
```

**No plan caching.** Every call to `EXECUTE` inside PL/pgSQL re-plans the dynamic SQL. For simple echo-style methods, planning overhead can exceed execution time at high call rates. `pg_stat_statements` will show the EXECUTE as a generic statement with limited per-method visibility.

**Identifier quoting gap.** `function_name` is stored in `jsonrpc.methods` as a qualified name (e.g., `jsonrpc.echo`). It should be split on `.` and each part quoted with `quote_ident`. Current `%s` is equivalent to string concatenation — any value containing `;`, `--`, or `$` can alter the generated SQL.

---

## 4. Response Construction Chain

```mermaid
flowchart TD
    M["Method function"]

    M -->|"has result"| SR
    M -->|"has error"| ER
    M -->|"result may be null"| GR

    SR["jsonrpc.success_response(request, result)\nRETURNS JSON\nlanguage plpgsql\n\njson_build_object(\n  'id',      request->>'id',\n  'jsonrpc', COALESCE(request->>'jsonrpc','2.0'),\n  'result',  result\n)"]

    ER["jsonrpc.error_response(request, code, msg, data)\nRETURNS JSON\nlanguage plpgsql\n\njson_build_object(\n  'id',      request->>'id',\n  'jsonrpc', COALESCE(request->>'jsonrpc','2.0'),\n  'error',   json_build_object(code,msg[,data])\n)"]

    GR["jsonrpc.get_response(request, p_jsonrpc†, p_id†, result, code, msg)\nRETURNS JSON\nlanguage sql\n\n† p_jsonrpc and p_id never used — dead params"]

    GR -->|"result IS NOT NULL"| SR
    GR -->|"result IS NULL"| ER

    SR --> OUT["JSON response to caller"]
    ER --> OUT
```

**`id` type coercion defect:**
```
Request:   {"id": 1, ...}           -- integer
Response:  {"id": "1", ...}         -- string  ← WRONG
```
`request->>'id'` uses the text extraction operator. Fix: use `request->'id'` (JSON extraction, preserves type).

---

## 5. Error Handling Map

```mermaid
flowchart TD
    ENTRY["jsonrpc.execute(p_request TEXT)"]

    subgraph INNER ["Inner block — parse"]
        CAST["p_request::JSON"]
        CAST -->|"EXCEPTION WHEN OTHERS"| E1["RETURN error_response(-32700)\ndata: [SQLSTATE, SQLERRM, context]"]
    end

    CAST -->|success| BATCHCHECK{"json starts\nwith '[' ?"}

    subgraph BATCHBLOCK ["Batch path"]
        BATCHCHECK -->|yes| EMPTYCHECK{"length = 0?"}
        EMPTYCHECK -->|yes| E2["RETURN error_response(-32600)"]
        EMPTYCHECK -->|no| BLOOP["FOR each element\n  recursive execute()\n  accumulate response"]
        BLOOP --> SWALLOW["EXCEPTION WHEN invalid_parameter_value\nTHEN NULL\n⚠ Dead — purpose unclear"]
    end

    BATCHCHECK -->|no| VALIDATE

    subgraph VALIDATE ["Validation"]
        V1{"method IS NULL?"}-->|yes| E3["-32600 Invalid Request"]
        V1 -->|no| V2{"id IS NULL?"}
        V2 -->|yes| E4["-32600 Invalid Request"]
        V2 -->|no| V3{"function IS NULL?"}
        V3 -->|yes| E5["-32601 Method not found"]
        V3 -->|no| EXEC["EXECUTE dynamic SQL"]
    end

    EXEC --> RESULT["RETURN l_response"]

    EXEC -->|"EXCEPTION WHEN OTHERS"| OUTER["RAISE NOTICE (diagnostics)\nRETURN error_response(-32099)\ndata: [request, SQLSTATE, SQLERRM, context]"]
```

---

## 6. PostgreSQL Runtime Characteristics

| Characteristic | Behavior | Risk |
|---|---|---|
| Transaction context | Inherits caller's transaction | Batch items are NOT independent |
| EXCEPTION blocks | Each creates an implicit savepoint | Low overhead per call |
| SECURITY model | SECURITY INVOKER (default) | Safe — caller's privileges apply |
| Plan caching | None — EXECUTE re-plans every call | High CPU at scale |
| WAL | Dispatch itself generates no WAL | Method functions may write |
| Lock acquisition | AccessShareLock on `jsonrpc.methods` | Negligible contention |
| Connection pooler compatibility | No session state set/read | Works with all pooler modes |
| RLS | Caller's policies apply | Correct — no RLS bypass |
