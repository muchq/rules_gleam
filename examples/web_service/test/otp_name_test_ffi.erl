-module(otp_name_test_ffi).
-export([hpack_application_loads/0]).

hpack_application_loads() ->
    {ok, _} = application:ensure_all_started(hpack),
    {ok, "0.3.0"} = application:get_key(hpack, vsn),
    "hpack" = filename:basename(code:lib_dir(hpack)),
    true.
