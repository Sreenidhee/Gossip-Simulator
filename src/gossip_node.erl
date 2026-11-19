%% Gossip actor.
%%
%% * Becomes active the first time it hears the rumor and then, on every
%%   `tick` (a message it sends to itself), tells the rumor to a random
%%   neighbour.
%% * Stops transmitting once it has heard the rumor `Limit` times (10).
%% * A stopped actor that is told the rumor again replies {done, Self}, so
%%   the sender drops it from its peer set. An active actor whose peer set
%%   becomes empty also stops.
%%
%% Messages to the main process: {heard, I} (first time) and {stopped, I}.
-module(gossip_node).
-export([spawn_node/5]).

-record(st, {i, peers, count = 0, limit, main, stopped = false}).

spawn_node(I, N, Topo, Limit, Main) ->
    spawn(fun() ->
                  Peers = topology:peers_new(Topo, I, N),
                  loop(#st{i = I, peers = Peers, limit = Limit, main = Main})
          end).

loop(#st{stopped = true, i = I} = S) ->
    receive
        {rumor, From} ->
            reply_done(From, I),
            loop(S);
        _ ->
            loop(S)
    end;
loop(#st{i = I, count = C, limit = Limit, main = Main} = S) ->
    receive
        {rumor, _From} ->
            C1 = C + 1,
            C =:= 0 andalso begin Main ! {heard, I}, topology:next_tick() end,
            case C1 >= Limit of
                true  -> stop(S#st{count = C1});
                false -> loop(S#st{count = C1})
            end;
        tick ->
            case topology:peers_pick(S#st.peers) of
                none ->
                    stop(S);
                J ->
                    topology:pid(J) ! {rumor, I},
                    topology:next_tick(),
                    loop(S)
            end;
        {done, J} ->
            Peers = topology:peers_remove(J, S#st.peers),
            %% Only an actor that has the rumor can run out of peers to tell.
            case C > 0 andalso topology:peers_pick(Peers) =:= none of
                true  -> stop(S#st{peers = Peers});
                false -> loop(S#st{peers = Peers})
            end
    end.

stop(#st{i = I, main = Main} = S) ->
    Main ! {stopped, I},
    loop(S#st{stopped = true}).

%% From = 0 means the rumor came from the main process.
reply_done(0, _I)   -> ok;
reply_done(From, I) -> topology:pid(From) ! {done, I}.
