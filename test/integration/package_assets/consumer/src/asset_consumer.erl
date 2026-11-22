-module(asset_consumer).
-export([main/0]).
-include_lib("asset_fixture/include/message.hrl").

main() ->
    ?MESSAGE = string:trim(binary_to_list(asset_fixture:read())),
    io:format("~s~n", [?MESSAGE]).
