\set ECHO none
BEGIN;
\t
\i sql/pgjsonrpc.sql
\set ECHO all

-- You should write your tests

SELECT jsonrpc.execute('{"id":1, "method":"test"}');

SELECT jsonrpc.execute('{"jsonrpc": "2.0", "id":1, "method":"echo", "params": {"message": "Hello jsonrpc!"}}');

INSERT INTO jsonrpc.methods(name, description, function_name)
VALUES('echotest', 'Echoes the parameter passed to echo.', 'jsonrpc.echo');

SELECT jsonrpc.execute('{"jsonrpc": "2.0", "id":1, "method":"echotest", "params": {"message": "Hello jsonrpc!"}}');

ROLLBACK;
