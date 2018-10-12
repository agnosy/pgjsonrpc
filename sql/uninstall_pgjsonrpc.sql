/*
 * Author: The maintainer's name
 * Created at: 2018-10-12 12:22:35 +0530
 *
 */

--
-- This is a example code genereted automaticaly
-- by pgxn-utils.

SET client_min_messages = warning;

BEGIN;

-- You can use this statements as
-- template for your extension.

DROP OPERATOR #? (text, text);
DROP FUNCTION pgjsonrpc(text, text);
DROP TYPE pgjsonrpc CASCADE;
COMMIT;
