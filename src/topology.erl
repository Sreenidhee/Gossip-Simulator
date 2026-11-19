%% Topology helpers: parsing, network size, and neighbour sets.
%%
%% Actors are numbered 1..N. Instead of handing every actor a list of
%% PIDs (which for the full network would cost O(N^2) memory), each actor
%% only stores neighbour *indices*. The index -> PID table lives in a
%% persistent_term tuple, which every actor can read without copying.
-module(topology).
-export([parse/1, actual_size/2, neighbors/3]).
-export([peers_new/3, peers_pick/1, peers_remove/2]).
-export([publish_pids/1, pid/1, next_tick/0]).

-define(PIDS_KEY, {project2, pids}).
-define(GOSSIP_TICK_MS, 1).

parse("full")  -> full;
parse("2D")    -> grid;
parse("2d")    -> grid;
parse("line")  -> line;
parse("imp2D") -> imp2d;
parse("imp2d") -> imp2d;
parse(Other)   -> erlang:error({bad_topology, Other}).

%% 2D-based topologies round N up to the next perfect square.
actual_size(T, N) when T =:= grid; T =:= imp2d ->
    K = ceil_sqrt(N),
    K * K;
actual_size(_, N) ->
    N.

ceil_sqrt(N) ->
    K = trunc(math:sqrt(N)),
    if K * K >= N -> K; true -> K + 1 end.

%% Static neighbour list for the non-full topologies.
neighbors(line, I, N) ->
    [J || J <- [I - 1, I + 1], J >= 1, J =< N];
neighbors(grid, I, N) ->
    K = ceil_sqrt(N),
    Row = (I - 1) div K,
    Col = (I - 1) rem K,
    [Row2 * K + Col2 + 1
     || {Row2, Col2} <- [{Row - 1, Col}, {Row + 1, Col}, {Row, Col - 1}, {Row, Col + 1}],
        Row2 >= 0, Row2 < K, Col2 >= 0, Col2 < K];
neighbors(imp2d, I, N) ->
    Grid = neighbors(grid, I, N),
    case N > length(Grid) + 1 of
        true  -> [random_other(N, [I | Grid]) | Grid];
        false -> Grid
    end.

random_other(N, Excluded) ->
    J = rand:uniform(N),
    case lists:member(J, Excluded) of
        true  -> random_other(N, Excluded);
        false -> J
    end.

%% ---------------------------------------------------------------------
%% Peer sets: the neighbours an actor may still talk to. A neighbour that
%% replies "I am done" is removed so nobody wastes messages on it.
%% Full network: {full, Self, N, RemovedMap}; everything else: {list, [J]}.
%% ---------------------------------------------------------------------
peers_new(full, I, N) -> {full, I, N, #{}};
peers_new(T, I, N)    -> {list, neighbors(T, I, N)}.

peers_pick({list, []}) ->
    none;
peers_pick({list, L}) ->
    lists:nth(rand:uniform(length(L)), L);
peers_pick({full, _I, N, Removed}) when map_size(Removed) >= N - 1 ->
    none;
peers_pick({full, I, N, Removed} = P) ->
    J0 = rand:uniform(N - 1),
    J = if J0 >= I -> J0 + 1; true -> J0 end,
    case maps:is_key(J, Removed) of
        true  -> peers_pick(P);
        false -> J
    end.

peers_remove(J, {list, L}) ->
    {list, lists:delete(J, L)};
peers_remove(J, {full, I, N, Removed}) ->
    Removed2 = Removed#{J => true},
    %% Rejection sampling gets slow once most peers are gone; switch to an
    %% explicit list of survivors at that point.
    case map_size(Removed2) * 2 > N of
        true  -> {list, [K || K <- lists:seq(1, N), K =/= I, not maps:is_key(K, Removed2)]};
        false -> {full, I, N, Removed2}
    end.

%% ---------------------------------------------------------------------
%% Index -> PID table.
%% ---------------------------------------------------------------------
publish_pids(PidTuple) ->
    persistent_term:put(?PIDS_KEY, PidTuple).

pid(J) ->
    element(J, persistent_term:get(?PIDS_KEY)).

%% Gossip actors transmit once per GOSSIP_TICK_MS. A timer (rather than
%% sending to ourselves in a tight loop) keeps actors from flooding a
%% neighbour with many rumors inside a single scheduler time slice.
next_tick() ->
    erlang:send_after(?GOSSIP_TICK_MS, self(), tick).
