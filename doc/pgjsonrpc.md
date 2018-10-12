pgjsonrpc
=========

Synopsis
--------

  An extension to support the JSON-RPC 2.0 specification.

Description
-----------

Implementation of JSON-RPC 2.0 specification as PostgreSQL extension.

Usage
-----

  CREATE EXTENSION pgjsonrpc;
  SELECT jsonrpc.execute('
    {"id": 1, "jsonrpc": "2.0", "method": "test", "params": [1, 2, 3]}
  ');

Support
-------

  N/A

Author
------

[agnosy]

Copyright and License
---------------------

Copyright (c) 2018 agnosy.

