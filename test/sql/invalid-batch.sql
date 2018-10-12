\set ECHO none
BEGIN;
\t
\i sql/pgjsonrpc.sql
\set ECHO all

-- You should write your tests

SELECT jsonrpc.execute('[1]');

ROLLBACK;
