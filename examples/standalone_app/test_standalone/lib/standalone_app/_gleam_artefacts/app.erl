-module(app).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/app.gleam").
-export([calculate_sum/1, double_all/1, main/0]).

-file("src/app.gleam", 22).
-spec calculate_sum(list(integer())) -> integer().
calculate_sum(Numbers) ->
    gleam@list:fold(Numbers, 0, fun(Acc, N) -> Acc + N end).

-file("src/app.gleam", 26).
-spec double_all(list(integer())) -> list(integer()).
double_all(Numbers) ->
    gleam@list:map(Numbers, fun(N) -> N * 2 end).

-file("src/app.gleam", 30).
-spec list_to_string(list(integer())) -> binary().
list_to_string(Numbers) ->
    _pipe = Numbers,
    _pipe@1 = gleam@list:map(_pipe, fun erlang:integer_to_binary/1),
    _pipe@2 = gleam@list:intersperse(_pipe@1, <<", "/utf8>>),
    _pipe@3 = gleam@list:fold(
        _pipe@2,
        <<""/utf8>>,
        fun(Acc, S) -> <<Acc/binary, S/binary>> end
    ),
    (fun(S@1) -> <<<<"["/utf8, S@1/binary>>/binary, "]"/utf8>> end)(_pipe@3).

-file("src/app.gleam", 5).
-spec main() -> nil.
main() ->
    gleam_stdlib:println(<<"🚀 Standalone Gleam App with Bazel!"/utf8>>),
    gleam_stdlib:println(<<""/utf8>>),
    Numbers = [1, 2, 3, 4, 5],
    gleam_stdlib:println(<<"Numbers: "/utf8, (list_to_string(Numbers))/binary>>),
    Sum = calculate_sum(Numbers),
    gleam_stdlib:println(
        <<"Sum: "/utf8, (erlang:integer_to_binary(Sum))/binary>>
    ),
    Doubled = double_all(Numbers),
    gleam_stdlib:println(<<"Doubled: "/utf8, (list_to_string(Doubled))/binary>>),
    gleam_stdlib:println(<<""/utf8>>),
    gleam_stdlib:println(<<"✅ App completed successfully!"/utf8>>).
