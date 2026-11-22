-module(asset_fixture).
-export([read/0]).
-include("message.hrl").

read() ->
    Path = filename:join(code:priv_dir(asset_fixture), "message.txt"),
    {ok, Bytes} = file:read_file(Path),
    Bytes = list_to_binary(?MESSAGE ++ "\n"),
    Bytes.
