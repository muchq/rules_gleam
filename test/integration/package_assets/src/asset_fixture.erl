-module(asset_fixture).
-export([read/0]).
-include("message.hrl").
-include("asset_paths.hrl").

read() ->
    Path = filename:join(code:priv_dir(asset_app), ?PRIV_FILE),
    {ok, Bytes} = file:read_file(Path),
    Bytes = list_to_binary(?MESSAGE ++ "\n"),
    Bytes.
