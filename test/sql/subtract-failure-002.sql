\set ECHO none
BEGIN;
\i sql/pgjsonrpc.sql
\set ECHO all

-- You should write your tests

SELECT jsonrpc.execute('
{
  "jsonrpc": "2.0",
  "method": "subtract",
  "params": [
    23,
    42
  ],
  "id": 2
}
');

ROLLBACK;
