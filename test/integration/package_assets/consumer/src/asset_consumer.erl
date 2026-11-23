-module(asset_consumer).
-export([main/0]).
-include_lib("asset_app/include/message.hrl").

main() ->
    ok = application:load(asset_app),
    {ok, "1.0.0"} = application:get_key(asset_app, vsn),
    ?MESSAGE = string:trim(binary_to_list(asset_fixture:read())),
    io:format("~s~n", [?MESSAGE]).
