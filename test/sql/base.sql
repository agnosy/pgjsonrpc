\set ECHO 0
BEGIN;
\i sql/pgjsonrpc.sql
\set ECHO all

-- You should write your tests

SELECT pgjsonrpc('foo', 'bar');

SELECT 'foo' #? 'bar' AS arrowop;

CREATE TABLE ab (
    a_field pgjsonrpc
);

INSERT INTO ab VALUES('foo' #? 'bar');
SELECT (a_field).a, (a_field).b FROM ab;

SELECT (pgjsonrpc('foo', 'bar')).a;
SELECT (pgjsonrpc('foo', 'bar')).b;

SELECT ('foo' #? 'bar').a;
SELECT ('foo' #? 'bar').b;

ROLLBACK;
