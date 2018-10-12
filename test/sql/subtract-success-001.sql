\set ECHO none
BEGIN;
\i sql/pgjsonrpc.sql

CREATE FUNCTION jsonrpc.subtract(p_request JSON)
RETURNS JSON AS
$function$
    SELECT jsonrpc.success_response(
        p_request,
        (
            (p_request->'params'->>'minuend')::BIGINT -
            (p_request->'params'->>'subtrahend')::BIGINT
        )
    );
$function$
LANGUAGE sql;

-- Create mapping from method echo to function_name
-- jsonrpc.echo
INSERT INTO jsonrpc.methods(name, description, function_name)
VALUES(
    'subtract',
    'Subtract the subtrahend from minuend passed in parameters.',
    'jsonrpc.subtract'
);

\set ECHO all

-- You should write your tests

SELECT jsonrpc.execute('
{
  "jsonrpc": "2.0",
  "method": "subtract",
  "params": {
    "minuend": 42,
    "subtrahend": 23
  },
  "id": 1
}
');

SELECT jsonrpc.execute('
{
  "jsonrpc": "2.0",
  "method": "subtract",
  "params": {
    "subtrahend": 23,
    "minuend": 42
  },
  "id": 1
}
');

SELECT jsonrpc.execute('
{
  "jsonrpc": "2.0",
  "method": "subtract",
  "params": {
    "minuend": 23,
    "subtrahend": 42
  },
  "id": 1
}
');

SELECT jsonrpc.execute('
{
  "jsonrpc": "2.0",
  "method": "subtract",
  "params": {
    "minuend": 23,
    "subtrahend": 42
  },
  "id": 1
}
');

ROLLBACK;
