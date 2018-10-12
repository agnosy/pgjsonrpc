\set ECHO none
BEGIN;
\t
\i sql/pgjsonrpc.sql

CREATE FUNCTION jsonrpc.subtract(p_request JSON)
RETURNS JSON AS
$function$
    SELECT jsonrpc.success_response(
        p_request,
        (
            (p_request->'params'->>0)::BIGINT -
            (p_request->'params'->>1)::BIGINT
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
[
    {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
    {"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},
    {"foo": "boo"},
    {"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},
    {"jsonrpc": "2.0", "method": "get_data", "id": "9"} 
]
');

ROLLBACK;
