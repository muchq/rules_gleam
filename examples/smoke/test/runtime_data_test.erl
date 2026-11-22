-module(runtime_data_test).
-include_lib("eunit/include/eunit.hrl").

dependency_runtime_data_is_available_test() ->
    ?assertEqual({ok, <<"transitive runtime configuration\n">>}, runtime_data:read()).
