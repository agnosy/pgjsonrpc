/*
 * Author: agnosy
 * Created at: 2018-10-12 12:22:35 +0530
 *
 */

--
-- This is a example code genereted automaticaly
-- by pgxn-utils.

SET client_min_messages = warning;

BEGIN;

-- Statements to uninstall the jsonrpc
-- PostgreSQL extension.

DROP TABLE jsonrpc.methods;
DROP FUNCTION jsonrpc.get_response();
DROP FUNCTION jsonrpc.execute();
DROP SCHEMA jsonrpc;
COMMIT;
