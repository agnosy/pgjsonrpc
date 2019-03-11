/*
 * Author: agnosy
 * Created at: 2018-10-12 12:22:35 +0530
 *
 */

--
-- This is the code supporting the implementation
-- of JSON-RPC 2.0 specification as PostgreSQL
-- extension.

SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS jsonrpc;

-- Table to hold the supported methods and
-- the corresponding functions
CREATE TABLE jsonrpc.methods (
    id              SERIAL NOT NULL PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL,
    function_name   TEXT NOT NULL,
    UNIQUE (name)
);

-- A helper function to construct the json-rpc success response
CREATE OR REPLACE FUNCTION jsonrpc.success_response(
    p_request   JSON,
    p_result    ANYELEMENT
)
RETURNS JSON AS
$function$
BEGIN
    RETURN json_build_object(
        'id', p_request->>'id',
        'jsonrpc', COALESCE(p_request->>'jsonrpc', '2.0'),
        'result', p_result
    );
END;
$function$
LANGUAGE plpgsql;


-- A helper function to construct the json-rpc error response
CREATE OR REPLACE FUNCTION jsonrpc.error_response(
    p_request JSON,
    p_code    INTEGER,
    p_message TEXT,
    p_data    JSON
)
RETURNS JSON AS
$function$
DECLARE
    l_response  JSON;
    l_error     JSON;
BEGIN
    IF p_data IS NULL
    THEN
        l_error :=
            json_build_object(
                'code', p_code,
                'message', p_message
            );
    ELSE
        l_error :=
            json_build_object(
                'code', p_code,
                'message', p_message,
                'data', p_data
            );
    END IF;
    RETURN
        json_build_object(
            'id', p_request->>'id',
            'jsonrpc', COALESCE(p_request->>'jsonrpc', '2.0'),
            'error', l_error
        );
END;
$function$
LANGUAGE plpgsql;

-- A helper function to construct the json-rpc response
CREATE OR REPLACE FUNCTION jsonrpc.get_response(
    p_request JSON,
    p_jsonrpc TEXT,
    p_id      TEXT,
    p_result  JSON,
    p_code    INTEGER,
    p_message TEXT
)
RETURNS JSON AS
$function$
    SELECT
        CASE
            WHEN p_result IS NULL
            THEN jsonrpc.error_response(p_request, p_code, p_message, NULL)
            ELSE jsonrpc.success_response(p_request, p_result)
        END;
$function$
LANGUAGE sql;

-- A function to execute the method specified by
-- the request json provided as input to the
-- function.
CREATE OR REPLACE FUNCTION jsonrpc.execute(p_request TEXT)
RETURNS JSON AS
$function$
DECLARE
    l_request       JSON;
    l_response      JSON;
    l_jsonrpc       TEXT := '2.0';
    l_id            TEXT;
    l_sql           TEXT;
    l_method_name   TEXT;
    l_function_name TEXT := '';
    l_error_context TEXT := '';
    l_code          INTEGER := 0;
    l_message       TEXT    := 'Default message that should never be displayed.';
    l_data          JSON;
    l_request_count INTEGER;
    l_request_item  JSON;
    l_response_item JSON;
BEGIN
    BEGIN
        l_request       := p_request::JSON;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS l_error_context = PG_EXCEPTION_CONTEXT;
        RAISE NOTICE 'Error Name: [%]', SQLERRM;
        RAISE NOTICE 'Error State: [%]', SQLSTATE;
        RAISE NOTICE 'Error Context: [%]', l_error_context;

        l_code := -32700;
        l_message := 'Parse error';
        l_data := json_build_array(
            FORMAT('SQLSTATE: [%s]', SQLSTATE),
            FORMAT('SQLERRM: [%s]', SQLERRM),
            l_error_context
        );

        RETURN jsonrpc.get_response(l_request, l_jsonrpc, l_id, NULL, l_code, l_message);
    END;

    -- If the request is a non empty array, then it is batch
    IF(substring(regexp_replace(l_request::TEXT, '^\s+', ''), 1, 1) = '[')
    THEN
        BEGIN
            l_request_count := json_array_length(l_request);
            IF l_request_count = 0
            THEN
                l_code := -32600;
                l_message := 'Invalid Request';
                RETURN jsonrpc.error_response(
                    l_request,
                    l_code,
                    l_message,
                    l_data
                );
            ELSE
                l_response := '[]';
                FOR l_request_item IN
                    SELECT * FROM json_array_elements(l_request)
                LOOP
                    l_response_item := jsonrpc.execute(l_request_item::TEXT);
                    l_response := l_response::jsonb || l_response_item::jsonb;
                END LOOP;
                RETURN l_response;
            END IF;
        EXCEPTION
            WHEN invalid_parameter_value THEN NULL;
        END;
    END IF;

    l_id            := l_request->>'id';
    l_jsonrpc       := COALESCE(l_request->>'jsonrpc', l_jsonrpc);
    l_method_name   := l_request->>'method';

    SELECT function_name INTO l_function_name
    FROM jsonrpc.methods
    WHERE name = l_method_name
    ;

    IF l_method_name IS NULL
    THEN
        l_code := -32600;
        l_message := 'Invalid Request';
    ELSIF l_id IS NULL
    THEN
        l_code := -32600;
        l_message := 'Invalid Request';
    ELSIF l_function_name IS NULL
    THEN
        l_code := -32601;
        l_message := 'Method not found';
        l_data := to_json(
            FORMAT(
                'Function corresponding to method(%s) not found',
                l_method_name
            )
        );
    END IF;

    IF l_code != 0
    THEN
        RETURN jsonrpc.get_response(l_request, l_jsonrpc, l_id, NULL, l_code, l_message);
    END IF;

    l_sql := FORMAT('SELECT %s(%L)', l_function_name, l_request);

    EXECUTE l_sql INTO l_response;

    RETURN l_response;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS l_error_context = PG_EXCEPTION_CONTEXT;
    RAISE NOTICE 'Error Name: [%]', SQLERRM;
    RAISE NOTICE 'Error State: [%]', SQLSTATE;
    RAISE NOTICE 'Error Context: [%]', l_error_context;
    RAISE NOTICE 'jsonrpc.execute([%]): []', p_request;

    l_code := -32099;
    l_message := 'Exception in jsonrpc.execute(...)';
    l_data := json_build_array(
        FORMAT('jsonrpc.execute([%s]): []', p_request),
        FORMAT('SQLSTATE: [%s]', SQLSTATE),
        FORMAT('SQLERRM: [%s]', SQLERRM),
        l_error_context
    );

    RETURN jsonrpc.get_response(l_request, l_jsonrpc, l_id, NULL, l_code, l_message);
END;
$function$
LANGUAGE plpgsql;


-- A function to execute the method specified by
-- the request json provided as input to the
-- function.
CREATE OR REPLACE FUNCTION jsonrpc.echo(p_request JSON)
RETURNS JSON AS
$function$
    SELECT jsonrpc.get_response(
        p_request,
        p_request->>'jsonrpc',
        p_request->>'id',
        p_request->'params'->'message',
        NULL,
        NULL
    );
$function$
LANGUAGE sql;

-- Create mapping from method echo to function_name
-- jsonrpc.echo
INSERT INTO jsonrpc.methods(name, description, function_name)
VALUES(
    'echo',
    'Echoes the message passed in the params.',
    'jsonrpc.echo'
);

