# Execution Flow

## Single Request

```
Caller
  │
  │  SELECT jsonrpc.execute('{"jsonrpc":"2.0","id":1,"method":"echo","params":{…}}')
  ▼
jsonrpc.execute(p_request TEXT)
  │
  ├─[1] Parse TEXT → JSON
  │       EXCEPTION → return error_response(-32700, "Parse error")
  │
  ├─[2] Is first non-whitespace char '['?
  │       YES → jump to Batch Path (below)
  │
  ├─[3] Extract fields
  │       l_id          := l_request->>'id'
  │       l_jsonrpc     := l_request->>'jsonrpc'
  │       l_method_name := l_request->>'method'
  │
  ├─[4] SELECT function_name FROM jsonrpc.methods WHERE name = l_method_name
  │
  ├─[5] Validate
  │       l_method_name IS NULL  → error_response(-32600, "Invalid Request")
  │       l_id IS NULL           → error_response(-32600, "Invalid Request")
  │       l_function_name IS NULL → error_response(-32601, "Method not found")
  │
  ├─[6] Build and run dynamic SQL
  │       l_sql := FORMAT('SELECT %s(%L)', l_function_name, l_request::TEXT)
  │       EXECUTE l_sql INTO l_response
  │       (method function calls success_response or error_response internally)
  │
  ├─[7] RETURN l_response
  │
  └─ EXCEPTION (outer)
          → RAISE NOTICE (diagnostic info)
          → return error_response(-32099, "Exception in jsonrpc.execute(...)")
```

---

## Batch Request

```
jsonrpc.execute('[{…}, {…}, {…}]')
  │
  ├─[1] Parse TEXT → JSON  (same as single)
  │
  ├─[2] Detect array, enter batch path
  │
  ├─[3] json_array_length(l_request)
  │       = 0  → error_response(-32600, "Invalid Request")
  │       > 0  → continue
  │
  ├─[4] l_response := '[]'
  │
  ├─[5] FOR l_request_item IN SELECT * FROM json_array_elements(l_request) LOOP
  │       │
  │       └─ l_response_item := jsonrpc.execute(l_request_item::TEXT)  ← RECURSIVE
  │          l_response := l_response::jsonb || l_response_item::jsonb
  │
  └─[6] RETURN l_response   (JSON array of individual responses)
```

---

## Response Helper Call Chain

```
Method function (e.g. jsonrpc.echo)
  │
  ├─ success path:
  │     jsonrpc.success_response(p_request, p_result)
  │       └─ json_build_object('id', p_request->>'id',
  │                            'jsonrpc', COALESCE(p_request->>'jsonrpc', '2.0'),
  │                            'result', p_result)
  │
  └─ error path:
        jsonrpc.error_response(p_request, p_code, p_message, p_data)
          └─ json_build_object('id', p_request->>'id',
                               'jsonrpc', COALESCE(p_request->>'jsonrpc', '2.0'),
                               'error', json_build_object('code', p_code,
                                                          'message', p_message
                                                          [, 'data', p_data]))
```

Alternatively, method functions may call `jsonrpc.get_response(...)`, which delegates to one of the two above based on `p_result IS NULL`.

---

## Error Code Map

| Trigger condition | Code | Message |
|---|---|---|
| `TEXT → JSON` cast fails | `-32700` | Parse error |
| `method` field is NULL or `id` is NULL | `-32600` | Invalid Request |
| Empty batch array `[]` | `-32600` | Invalid Request |
| `method` not found in `jsonrpc.methods` | `-32601` | Method not found |
| Unhandled exception in dispatch | `-32099` | Exception in jsonrpc.execute(...) |

---

## Dynamic Dispatch Detail

```sql
-- l_function_name = 'jsonrpc.echo'
-- l_request       = '{"jsonrpc":"2.0","id":"1","method":"echo","params":{"message":"hi"}}'

l_sql := FORMAT('SELECT %s(%L)', l_function_name, l_request);
-- expands to:
--   SELECT jsonrpc.echo('{"jsonrpc":"2.0","id":"1","method":"echo","params":{"message":"hi"}}')

EXECUTE l_sql INTO l_response;
```

`%L` in `FORMAT` produces a properly quoted SQL string literal for the request argument. `%s` for `function_name` is unquoted (see Technical Debt).
