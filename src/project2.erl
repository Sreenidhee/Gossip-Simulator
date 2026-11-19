%% Gossip / Push-Sum simulator.
%%
%% Usage: project2 numNodes topology algorithm
%%   topology  : full | 2D | line | imp2D
%%   algorithm : gossip | push-sum
-module(project2).
-export([main/0, main/1, run/3]).

-define(GOSSIP_LIMIT, 10).
%% When every actor that got involved has stopped but some never did, wait
%% this long for stray in-flight messages before declaring the run stalled.
-define(STALL_GRACE_MS, 200).

main() ->
    main([]).

main([NStr, TopoStr, AlgStr]) ->
    try {list_to_integer(NStr), topology:parse(TopoStr), parse_alg(AlgStr)} of
        {N, Topo, Alg} when N > 1 ->
            run(N, Topo, Alg),
            erlang:halt(0);
        _ ->
            usage()
    catch
        error:_ -> usage()
    end;
main(_) ->
    usage().

usage() ->
    io:format("usage: project2 numNodes full|2D|line|imp2D gossip|push-sum~n"),
    erlang:halt(1).

parse_alg("gossip")   -> gossip;
parse_alg("push-sum") -> pushsum;
parse_alg("pushsum")  -> pushsum;
parse_alg(Other)      -> erlang:error({bad_algorithm, Other}).

run(Requested, Topo, Alg) ->
    N = topology:actual_size(Topo, Requested),
    Main = self(),
    {SetupUs, Pids} = measure_running_time(fun() -> spawn_all(N, Topo, Alg, Main) end),
    topology:publish_pids(Pids),
    Starter = rand:uniform(N),
    {Us, Res} = measure_running_time(fun() -> converge(Alg, N, Starter) end),
    report(Requested, N, Topo, Alg, SetupUs, Us, Res),
    {Us, Res}.

measure_running_time(Fun) ->
    Start = erlang:monotonic_time(microsecond),
    Res = Fun(),
    End = erlang:monotonic_time(microsecond),
    Duration = End - Start,
    {Duration, Res}.

spawn_all(N, Topo, gossip, Main) ->
    list_to_tuple([gossip_node:spawn_node(I, N, Topo, ?GOSSIP_LIMIT, Main) || I <- lists:seq(1, N)]);
spawn_all(N, Topo, pushsum, Main) ->
    list_to_tuple([pushsum_node:spawn_node(I, N, Topo, Main) || I <- lists:seq(1, N)]).

%% ---------------------------------------------------------------------
%% Convergence detection.
%% ---------------------------------------------------------------------
converge(gossip, N, Starter) ->
    topology:pid(Starter) ! {rumor, 0},
    gossip_wait(N, 0, 0);
converge(pushsum, N, Starter) ->
    topology:pid(Starter) ! start,
    pushsum_wait(N, 0, []).

%% Converged once every actor has heard the rumor at least once.
gossip_wait(N, N, Stopped) ->
    {converged, N, Stopped};
gossip_wait(N, Heard, Stopped) ->
    Timeout = case Heard > 0 andalso Stopped =:= Heard of
                  true  -> ?STALL_GRACE_MS;   %% nobody left transmitting
                  false -> infinity
              end,
    receive
        {heard, _}   -> gossip_wait(N, Heard + 1, Stopped);
        {stopped, _} -> gossip_wait(N, Heard, Stopped + 1)
    after Timeout ->
            {stalled, Heard, Stopped}
    end.

%% Converged once every actor has terminated. The (s, w) message never
%% disappears (terminated actors relay it), so this cannot stall.
pushsum_wait(N, N, Estimates) ->
    {converged, N, Estimates};
pushsum_wait(N, Done, Estimates) ->
    receive
        {converged, _, R} -> pushsum_wait(N, Done + 1, [R | Estimates])
    end.

%% ---------------------------------------------------------------------
%% Output.
%% ---------------------------------------------------------------------
report(Requested, N, Topo, Alg, SetupUs, Us, Res) ->
    io:format("Nodes: ~p (requested ~p)  Topology: ~s  Algorithm: ~s~n",
              [N, Requested, topo_name(Topo), alg_name(Alg)]),
    io:format("Setup time: ~.3f ms~n", [SetupUs / 1000]),
    {Status, Reached, Extra} = details(Alg, N, Res),
    io:format("Status: ~s (~p/~p actors)~n", [Status, Reached, N]),
    Extra =/= "" andalso io:format("~s~n", [Extra]),
    io:format("Convergence time: ~p microseconds (~.3f ms)~n", [Us, Us / 1000]),
    %% Machine-readable line used by the experiment scripts.
    io:format("RESULT,~p,~s,~s,~p,~s,~p,~s~n",
              [N, topo_name(Topo), alg_name(Alg), Us, Status, Reached, csv_extra(Alg, N, Res)]).

details(gossip, _N, {Status, Heard, _Stopped}) ->
    {Status, Heard, ""};
details(pushsum, N, {Status, Done, Est}) ->
    {Mean, MaxErr} = estimate_stats(N, Est),
    True = (N + 1) / 2,
    {Status, Done,
     io_lib:format("True average: ~.6f  mean estimate: ~.6f  max relative error: ~.3e  (sum estimate ~.6f)",
                   [True, Mean, MaxErr, Mean * N])}.

csv_extra(gossip, _, _) -> "";
csv_extra(pushsum, N, {_, _, Est}) ->
    {Mean, MaxErr} = estimate_stats(N, Est),
    io_lib:format("~.10f,~.6e", [Mean, MaxErr]).

estimate_stats(_N, []) ->
    {0.0, 0.0};
estimate_stats(N, Est) ->
    True = (N + 1) / 2,
    Mean = lists:sum(Est) / length(Est),
    MaxErr = lists:max([abs(E - True) / True || E <- Est]),
    {Mean, MaxErr}.

topo_name(full)  -> "full";
topo_name(grid)  -> "2D";
topo_name(line)  -> "line";
topo_name(imp2d) -> "imp2D".

alg_name(gossip)  -> "gossip";
alg_name(pushsum) -> "push-sum".
