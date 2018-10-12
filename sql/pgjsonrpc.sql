/*
 * Author: The maintainer's name
 * Created at: 2018-10-12 12:22:35 +0530
 *
 */

--
-- This is a example code genereted automaticaly
-- by pgxn-utils.

SET client_min_messages = warning;

-- If your extension will create a type you can
-- do somenthing like this
CREATE TYPE pgjsonrpc AS ( a text, b text );

-- Maybe you want to create some function, so you can use
-- this as an example
CREATE OR REPLACE FUNCTION pgjsonrpc (text, text)
RETURNS pgjsonrpc LANGUAGE SQL AS 'SELECT ROW($1, $2)::pgjsonrpc';

-- Sometimes it is common to use special operators to
-- work with your new created type, you can create
-- one like the command bellow if it is applicable
-- to your case

CREATE OPERATOR #? (
	LEFTARG   = text,
	RIGHTARG  = text,
	PROCEDURE = pgjsonrpc
);
