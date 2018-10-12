/*
 * Author: X
 * Created at: 2018-10-12 12:22:35 +0530
 *
 */

--
-- This is the code supporting the implementation
-- of JSON-RPC 2.0 specification as PostgreSQL
-- extension.

SET client_min_messages = warning;

-- Table to hold the supported methods and
-- the corresponding functions
CREATE TABLE jsonrpc.methods AS (
    id              SERIAL NOT NULL PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL,
    function_name   TEXT NOT NULL,
    UNIQUE (name, function_name)
);

-- A helper function to get the json-rpc response
-- as json
CREATE OR REPLACE FUNCTION jsonrpc.get_response(
    p_jsonrpc TEXT,
    p_id      TEXT,
    p_result  JSON,
    p_code    INTEGER,
    p_message TEXT
)
RETURNS JSON AS
$function$
DECLARE
    l_response  JSON;
    l_error     JSON;
BEGIN
    IF p_result IS NULL
    THEN
        l_error := json_build_object(
                     'code', p_code,
                     'message', p_message
                   );
        l_response := json_build_object(
                        'id', p_id,
                        'jsonrpc', p_jsonrpc,
                        'error', l_error
                      );
    ELSE
        l_response := json_build_object(
                        'id', p_id,
                        'jsonrpc', p_jsonrpc,
                        'result', p_result
                      );
    END IF;
    RETURN l_response;
END;
$function$
LANGUAGE plpgsql;

-- A function to execute the method specified by
-- the request json provided as input to the
-- function.
CREATE FUNCTION jsonrpc.execute(p_request JSON)
RETURNS JSON AS
$function$
DECLARE
    l_params        JSON;
    l_response      JSON;
    l_jsonrpc       TEXT;
    l_id            TEXT;
    l_sql           TEXT;
    l_method_name   TEXT;
    l_function_name TEXT := '';
    l_error_context TEXT := '';
    l_code          INTEGER;
    l_message       TEXT;
BEGIN
    l_id            := p_request->>'id';
    l_jsonrpc       := p_request->>'jsonrpc';
    l_params        := p_request->>'params';
    l_method_name   := p_request->>'method';

    SELECT function_name INTO l_function_name
    FROM jsonrpc.methods
    WHERE name = l_method_name
    ;

    IF l_method_name IS NULL
    THEN
        l_code := -32600;
        l_message := 'Invalid Request. Missing method.';
    ELSIF l_id IS NULL
    THEN
        l_code := -32600;
        l_message := 'Invalid Request. Missing id';
    ELSIF l_function_name IS NULL
    THEN
        l_code := -32601;
        l_message := FORMAT('%s: Method not found', l_method_name);
    END IF;

    IF l_code IS NOT NULL OR l_message IS NOT NULL
    THEN
        RETURN jsonrpc.get_response(l_jsonrpc, l_id, NULL, l_code, l_message);
    END IF;

    l_sql := FORMAT('SELECT %s(%L)', l_method_name, p_request);

    EXECUTE l_sql INTO l_response;

    RETURN l_response;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS l_error_context = PG_EXCEPTION_CONTEXT;
    RAISE INFO 'Error Name: [%]', SQLERRM;
    RAISE INFO 'Error State: [%]', SQLSTATE;
    RAISE INFO 'Error Context: [%]', l_error_context;

    RETURN jsonrpc.get_response(NULL, NULL, NULL, -32700, 'Parse error');
END;
$function$
LANGUAGE plpgsql;

