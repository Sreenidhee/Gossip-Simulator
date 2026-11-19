#!/usr/bin/env escript
%% Runs the experiments used in the report and writes the results to a CSV file.
%%
%% Usage (from the project folder):
%%   escript experiments/run_experiments.escript base    -> experiments/results_base.csv
%%   escript experiments/run_experiments.escript bonus   -> experiments/results_bonus.csv
%%
%% Every run is started as a separate ./project2 process, one after the
%% other, so runs don't slow each other down. We read the RESULT line that
%% project2 prints at the end.

-define(TIMEOUT_MS, 900000).        % give up on a run after 15 minutes
-define(REPEAT_IF_UNDER_MS, 30000). % only repeat runs that are quick
-define(REPS, 3).

main(["base"]) ->
    base();
main(["bonus"]) ->
    bonus();
main(_) ->
    io:format("usage: escript run_experiments.escript base|bonus~n"),
    halt(1).

%% ---------------------------------------------------------------------
%% Base project: increase the size until a run times out.
%% ---------------------------------------------------------------------
base() ->
    Sizes = [{"gossip", "full",    [100, 300, 1000, 3000, 10000, 30000, 100000, 300000, 1000000]},
             {"gossip", "imp2D",   [100, 300, 1000, 3000, 10000, 30000, 100000, 300000, 1000000]},
             {"gossip", "2D",      [100, 300, 1000, 3000, 10000, 30000, 100000, 300000]},
             {"gossip", "line",    [100, 300, 1000, 3000, 10000, 30000, 100000]},
             {"push-sum", "full",  [100, 300, 1000, 3000, 10000, 30000, 100000, 300000]},
             {"push-sum", "imp2D", [100, 300, 1000, 3000, 10000, 30000, 100000]},
             {"push-sum", "2D",    [100, 300, 1000, 3000, 10000]},
             {"push-sum", "line",  [100, 200, 300, 600, 1000, 2000, 3000]}],
    {ok, F} = file:open(csv_path("results_base.csv"), [append]),
    [series(F, Alg, Topo, Ns) || {Alg, Topo, Ns} <- Sizes],
    file:close(F).

series(_F, _Alg, _Topo, []) ->
    ok;
series(F, Alg, Topo, [N | Rest]) ->
    case repeat(F, Alg, Topo, N, 0) of
        ok      -> series(F, Alg, Topo, Rest);
        timeout -> ok   % too slow, don't try bigger sizes
    end.

repeat(_F, _Alg, _Topo, _N, ?REPS) ->
    ok;
repeat(F, Alg, Topo, N, Rep) ->
    Args = [integer_to_list(N), Topo, Alg],
    {Ms, Res} = run(Args, ?TIMEOUT_MS),
    io:format("~s ~s ~p rep ~p: ~p ms ~s~n", [Alg, Topo, N, Rep, Ms, show(Res)]),
    case Res of
        timeout ->
            timeout;
        Fields ->
            write_row(F, [Alg, Topo, integer_to_list(N), integer_to_list(Rep)] ++ pad(Fields, 8)),
            case Ms > ?REPEAT_IF_UNDER_MS of
                true  -> ok;
                false -> repeat(F, Alg, Topo, N, Rep + 1)
            end
    end.

%% ---------------------------------------------------------------------
%% Bonus: sweep the failure parameters.
%% ---------------------------------------------------------------------
bonus() ->
    Fails = ["0.0", "0.05", "0.1", "0.2", "0.3", "0.4", "0.5"],
    GossipDrops = ["0.0", "0.1", "0.2", "0.3", "0.5", "0.7"],
    PushSumDrops = ["0.0", "0.001", "0.003", "0.01", "0.03", "0.05"],
    Plan =
        [{"gossip", T, "1000", ["fail=" ++ X, "drop=0", "idle=2000"]}
         || T <- ["full", "imp2D", "2D", "line"], X <- Fails] ++
        [{"gossip", T, "1000", ["fail=0", "drop=" ++ X, "idle=2000"]}
         || T <- ["full", "imp2D", "2D", "line"], X <- GossipDrops] ++
        [{"push-sum", T, "300", ["fail=" ++ X, "drop=0", "idle=10000"]}
         || T <- ["full", "imp2D", "2D"], X <- Fails] ++
        [{"push-sum", T, "300", ["fail=0", "drop=" ++ X, "idle=120000"]}
         || T <- ["full", "imp2D", "2D"], X <- PushSumDrops],
    {ok, F} = file:open(csv_path("results_bonus.csv"), [append]),
    [bonus_point(F, Alg, Topo, N, Opts, 0) || {Alg, Topo, N, Opts} <- Plan],
    file:close(F).

bonus_point(_F, _Alg, _Topo, _N, _Opts, ?REPS) ->
    ok;
bonus_point(F, Alg, Topo, N, Opts, Rep) ->
    {Ms, Res} = run([N, Topo, Alg | Opts], 300000),
    io:format("~s ~s ~s ~s rep ~p: ~p ms ~s~n",
              [Alg, Topo, N, lists:join(" ", Opts), Rep, Ms, show(Res)]),
    case Res of
        timeout ->
            ok;
        Fields ->
            write_row(F, [Alg, Topo, N, integer_to_list(Rep)] ++ pad(Fields, 12)),
            bonus_point(F, Alg, Topo, N, Opts, Rep + 1)
    end.

%% ---------------------------------------------------------------------
%% Running ./project2 and reading its RESULT line.
%% ---------------------------------------------------------------------
run(Args, Timeout) ->
    Exe = filename:join(project_dir(), "project2"),
    T0 = erlang:monotonic_time(millisecond),
    Port = open_port({spawn_executable, Exe},
                     [{args, Args}, exit_status, stderr_to_stdout, {line, 4096}]),
    Res = collect(Port, Timeout, none),
    {erlang:monotonic_time(millisecond) - T0, Res}.

collect(Port, Timeout, Result) ->
    receive
        {Port, {data, {eol, "RESULT," ++ Rest}}} ->
            collect(Port, Timeout, string:split(Rest, ",", all));
        {Port, {data, _}} ->
            collect(Port, Timeout, Result);
        {Port, {exit_status, _}} when Result =:= none ->
            timeout;
        {Port, {exit_status, _}} ->
            Result
    after Timeout ->
            case erlang:port_info(Port, os_pid) of
                {os_pid, Pid} -> os:cmd("kill -9 " ++ integer_to_list(Pid));
                _ -> ok
            end,
            try port_close(Port) catch _:_ -> ok end,
            timeout
    end.

%% ---------------------------------------------------------------------
%% Helpers.
%% ---------------------------------------------------------------------
project_dir() ->
    filename:dirname(filename:dirname(filename:absname(escript:script_name()))).

csv_path(Name) ->
    filename:join([project_dir(), "experiments", Name]).

pad(Fields, Len) when length(Fields) >= Len -> lists:sublist(Fields, Len);
pad(Fields, Len) -> Fields ++ lists:duplicate(Len - length(Fields), "").

show(timeout) -> "timeout";
show(Fields)  -> lists:join(",", Fields).

write_row(F, Fields) ->
    io:format(F, "~s~n", [lists:join(",", Fields)]).
