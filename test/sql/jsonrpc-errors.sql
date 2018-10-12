\set ECHO none
BEGIN;
\i sql/pgjsonrpc.sql
\set ECHO all

-- You should write your tests

SELECT jsonrpc.execute('{"jsonrpc": "2.0", "method": "foobar", "id": "1"}');
SELECT jsonrpc.execute('{"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]');
SELECT jsonrpc.execute('{"jsonrpc": "2.0", "method": 1, "params": "bar"}');
SELECT jsonrpc.execute('
[
  {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
  {"jsonrpc": "2.0", "method"
]
');
SELECT jsonrpc.execute('[]');

ROLLBACK;
