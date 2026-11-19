%% Push-Sum actor (receive-driven, as in the assignment).
%%
%% State (s, w) starts as (i, 1). The main process sends `start` to one
%% actor, which keeps half of (s, w) and sends the other half to a random
%% neighbour. From then on, every actor that receives a pair adds it to its
%% own (s, w), then keeps half and sends half to a random neighbour. So a
%% single (s, w) message travels through the network.
%%
%% A "round" is one received pair. If s/w changes by less than 1e-10 in 3
%% consecutive rounds the actor terminates and reports its estimate.
%% A terminated actor no longer updates its state; it simply relays any
%% pair it receives to a random neighbour, so the message can still reach
%% the actors that have not terminated yet.
%%
%% Messages to the main process: {converged, I, Ratio}.
-module(pushsum_node).
-export([spawn_node/4]).

-define(EPS, 1.0e-10).
-define(STABLE_ROUNDS, 3).

-record(st, {i, s, w, stable = 0, done = false, peers, main}).

spawn_node(I, N, Topo, Main) ->
    spawn(fun() ->
                  Peers = topology:peers_new(Topo, I, N),
                  loop(#st{i = I, s = float(I), w = 1.0, peers = Peers, main = Main})
          end).

loop(#st{done = true} = S) ->
    receive
        {push, Sx, Wx} ->
            send_to_random(S, Sx, Wx),
            loop(S);
        _ ->
            loop(S)
    end;
loop(#st{s = Sv, w = Wv} = S) ->
    receive
        start ->
            loop(send_half(S));
        {push, Sx, Wx} ->
            Old = Sv / Wv,
            Sv2 = Sv + Sx,
            Wv2 = Wv + Wx,
            New = Sv2 / Wv2,
            Stable = case abs(New - Old) < ?EPS of
                         true  -> S#st.stable + 1;
                         false -> 0
                     end,
            S2 = send_half(S#st{s = Sv2, w = Wv2, stable = Stable}),
            case Stable >= ?STABLE_ROUNDS of
                true ->
                    S2#st.main ! {converged, S2#st.i, New},
                    loop(S2#st{done = true});
                false ->
                    loop(S2)
            end
    end.

send_half(#st{s = Sv, w = Wv} = S) ->
    Hs = Sv / 2,
    Hw = Wv / 2,
    send_to_random(S, Hs, Hw),
    S#st{s = Hs, w = Hw}.

send_to_random(#st{peers = Peers}, Sx, Wx) ->
    J = topology:peers_pick(Peers),
    topology:pid(J) ! {push, Sx, Wx}.
