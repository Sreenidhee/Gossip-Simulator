#!/usr/bin/env escript
%% Draws the graphs for the report from the experiment CSV files and builds
%% the PDF.
%%
%% Usage (from the project folder):
%%   escript experiments/make_report.escript base    -> Report.pdf
%%   escript experiments/make_report.escript bonus   -> Report-bonus.pdf
%%
%% The graphs are written as SVG files to experiments/figures/. They are then
%% put into experiments/report_base.html (or report_bonus.html) wherever the
%% page says {{fig:name}}, and Google Chrome (headless) prints the page to PDF.

-define(CHROME, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").

-define(TOPOS, ["full", "imp2D", "2D", "line"]).

main(["base"]) ->
    Rows = read_csv("results_base.csv"),
    base_figures(Rows),
    build_pdf("report_base.html", "Report.pdf");
main(["bonus"]) ->
    Rows = read_csv("results_bonus.csv"),
    bonus_figures(Rows),
    build_pdf("report_bonus.html", "Report-bonus.pdf");
main(_) ->
    io:format("usage: escript make_report.escript base|bonus~n"),
    halt(1).

%% ---------------------------------------------------------------------
%% Base project graphs.
%% CSV columns: alg, topo, requested n, rep, n, topo, alg, time_us, status,
%%              reached, mean estimate, max error
%% ---------------------------------------------------------------------
base_figures(Rows) ->
    Ok = [R || R <- Rows, lists:nth(9, R) =:= "converged"],
    lists:foreach(
      fun(Alg) ->
              Series = [{Topo, medians([{num(lists:nth(5, R)), num(lists:nth(8, R)) / 1000}
                                        || R <- Ok, hd(R) =:= Alg, lists:nth(2, R) =:= Topo])}
                        || Topo <- ?TOPOS],
              save("base_" ++ Alg,
                   chart(Series, #{xlabel => "Number of actors (log scale)",
                                   ylabel => "Convergence time, ms (log scale)",
                                   xlog => true, ylog => true, w => 720, h => 440}))
      end, ["gossip", "push-sum"]),
    Errors = [{Topo, medians([{num(lists:nth(5, R)), max(num(lists:nth(12, R)), 1.0e-16)}
                              || R <- Ok, hd(R) =:= "push-sum", lists:nth(2, R) =:= Topo,
                                 lists:nth(12, R) =/= ""])}
              || Topo <- ?TOPOS],
    save("base_pushsum_error",
         chart(Errors, #{xlabel => "Number of actors (log scale)",
                         ylabel => "Max relative error (log scale)",
                         xlog => true, ylog => true, w => 720, h => 380})).

%% ---------------------------------------------------------------------
%% Bonus graphs.
%% CSV columns: alg, topo, requested n, rep, n, topo, alg, fail, drop, alive,
%%              time_us, progress_us, status, reached, mean estimate, max error
%% ---------------------------------------------------------------------
bonus_figures(Rows) ->
    Runs = [#{alg => lists:nth(1, R), topo => lists:nth(2, R),
              fail => num(lists:nth(8, R)), drop => num(lists:nth(9, R)),
              frac => num(lists:nth(14, R)) / num(lists:nth(10, R)),
              ms => num(lists:nth(12, R)) / 1000,
              status => lists:nth(13, R),
              err => case lists:nth(16, R) of "" -> none; E -> num(E) end}
            || R <- Rows],
    Coverage = fun(#{frac := F}) -> 100 * F end,
    Time = fun(#{ms := Ms}) -> Ms end,
    TimeIfDone = fun(#{status := "converged", ms := Ms}) -> Ms; (_) -> none end,
    Err = fun(#{err := none}) -> none;
             (#{frac := F}) when F == 0 -> none;
             (#{err := E}) -> max(E, 1.0e-16) end,
    FailX = "Fraction of actors crashed (fail=F)",
    DropX = "Message drop probability (drop=P)",
    Figs = [{"bonus_gossip_fail_coverage", "gossip", fail, Coverage, "Live actors reached (%)", false, FailX},
            {"bonus_gossip_drop_time", "gossip", drop, Time, "Time to last new actor, ms (log)", true, DropX},
            {"bonus_pushsum_fail_coverage", "push-sum", fail, Coverage, "Live actors converged (%)", false, FailX},
            {"bonus_pushsum_drop_time", "push-sum", drop, TimeIfDone,
             "Time until all live actors terminated, ms (log)", true, DropX},
            {"bonus_pushsum_drop_error", "push-sum", drop, Err, "Max relative error (log)", true, DropX}],
    lists:foreach(
      fun({Name, Alg, Which, Metric, YLabel, YLog, XLabel}) ->
              Series = [{Topo, sweep(Runs, Alg, Topo, Which, Metric)} || Topo <- ?TOPOS],
              Opts = #{xlabel => XLabel, ylabel => YLabel, xlog => false, ylog => YLog,
                       w => 640, h => 360},
              save(Name, chart(Series, case YLog of
                                            true -> Opts;
                                            false -> Opts#{ymin => 0, ymax => 105,
                                                           yticks => [0, 20, 40, 60, 80, 100]}
                                        end))
      end, Figs).

%% Mean of Metric for each value of the swept parameter (the other one = 0).
sweep(Runs, Alg, Topo, Which, Metric) ->
    Other = case Which of fail -> drop; drop -> fail end,
    Mine = [R || #{alg := A, topo := T} = R <- Runs, A =:= Alg, T =:= Topo,
                 maps:get(Other, R) == 0],
    Xs = lists:usort([maps:get(Which, R) || R <- Mine]),
    lists:flatmap(
      fun(X) ->
              case [V || R <- Mine, maps:get(Which, R) == X, V <- [Metric(R)], V =/= none] of
                  []   -> [];
                  Vals -> [{X, lists:sum(Vals) / length(Vals)}]
              end
      end, Xs).

%% ---------------------------------------------------------------------
%% Line chart as SVG: one line per topology, legend in a row above the plot.
%% ---------------------------------------------------------------------
-define(L, 78).   % left margin
-define(R, 20).
-define(T, 40).   % room for the legend
-define(B, 52).

chart(Series0, Opts) ->
    Series = [{T, Pts} || {T, Pts} <- Series0, Pts =/= []],
    #{w := W, h := H, xlog := XLog, ylog := YLog} = Opts,
    AllX = [X || {_, Pts} <- Series, {X, _} <- Pts],
    AllY = [Y || {_, Pts} <- Series, {_, Y} <- Pts],
    {X0, X1, XTicks} = axis_range(AllX, XLog, maps:get(xticks, Opts, auto)),
    {Y0, Y1, YTicks} = case maps:is_key(ymin, Opts) of
                           true  -> {maps:get(ymin, Opts), maps:get(ymax, Opts), maps:get(yticks, Opts)};
                           false -> axis_range(AllY, YLog, auto)
                       end,
    PW = W - ?L - ?R,
    PH = H - ?T - ?B,
    SX = fun(X) -> ?L + PW * (tr(X, XLog) - tr(X0, XLog)) / (tr(X1, XLog) - tr(X0, XLog)) end,
    SY = fun(Y) -> ?T + PH - PH * (tr(Y, YLog) - tr(Y0, YLog)) / (tr(Y1, YLog) - tr(Y0, YLog)) end,
    Grid = [[line(SX(X), ?T, SX(X), ?T + PH, "#e4e3df", 0.8),
             text(SX(X), ?T + PH + 18, tick_label(X, XLog), "middle", 11, "#52514e")]
            || X <- XTicks] ++
           [[line(?L, SY(Y), ?L + PW, SY(Y), "#e4e3df", 0.8),
             text(?L - 8, SY(Y) + 4, tick_label(Y, YLog), "end", 11, "#52514e")]
            || Y <- YTicks],
    Axes = [line(?L, ?T + PH, ?L + PW, ?T + PH, "#8a8984", 1),
            line(?L, ?T, ?L, ?T + PH, "#8a8984", 1),
            text(?L + PW / 2, H - 12, maps:get(xlabel, Opts), "middle", 12, "#0b0b0b"),
            io_lib:format("<text x=\"16\" y=\"~.1f\" transform=\"rotate(-90 16 ~.1f)\" "
                          "text-anchor=\"middle\" font-size=\"12\" fill=\"#0b0b0b\">~s</text>",
                          [?T + PH / 2, ?T + PH / 2, maps:get(ylabel, Opts)])],
    Lines = [begin
                 C = color(T),
                 P = [io_lib:format("~.1f,~.1f ", [float(SX(X)), float(SY(Y))]) || {X, Y} <- Pts],
                 [io_lib:format("<polyline points=\"~s\" fill=\"none\" stroke=\"~s\" "
                                "stroke-width=\"2\" stroke-linejoin=\"round\"/>", [P, C]),
                  [marker(T, SX(X), SY(Y)) || {X, Y} <- Pts]]
             end || {T, Pts} <- Series],
    Legend = legend([T || {T, _} <- Series]),
    io_lib:format("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"~p\" height=\"~p\" "
                  "viewBox=\"0 0 ~p ~p\" font-family=\"Helvetica, Arial, sans-serif\">"
                  "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>~s~s~s~s</svg>~n",
                  [W, H, W, H, Grid, Axes, Lines, Legend]).

legend(Topos) ->
    {Parts, _} = lists:mapfoldl(
                   fun(T, X) ->
                           C = color(T),
                           Part = [line(X, 18, X + 28, 18, C, 2), marker(T, X + 14, 18),
                                   text(X + 36, 22, label(T), "start", 12, "#0b0b0b")],
                           {Part, X + 52 + 7 * length(label(T))}
                   end, ?L, Topos),
    Parts.

%% Log axes snap to whole powers of ten; linear axes start at 0.
axis_range(Vals, true, _) ->
    Lo = floor(math:log10(lists:min(Vals))),
    Hi = ceil(math:log10(lists:max(Vals))),
    Hi2 = if Hi =:= Lo -> Hi + 1; true -> Hi end,
    {math:pow(10, Lo), math:pow(10, Hi2), [math:pow(10, E) || E <- lists:seq(Lo, Hi2)]};
axis_range(Vals, false, auto) ->
    Max = lists:max(Vals),
    Step = nice_step(Max / 5),
    Top = Step * ceil(Max / Step),
    {0, Top, [I * Step || I <- lists:seq(0, round(Top / Step))]}.

nice_step(Raw) ->
    E = math:pow(10, floor(math:log10(Raw))),
    hd([S * E || S <- [1, 2, 5, 10], S * E >= Raw]).

tr(V, true)  -> math:log10(V);
tr(V, false) -> V.

tick_label(V, true) ->
    io_lib:format("10<tspan dy=\"-6\" font-size=\"9\">~p</tspan>", [round(math:log10(V))]);
tick_label(V, false) when V == round(V) ->
    integer_to_list(round(V));
tick_label(V, false) ->
    float_to_list(float(V), [{decimals, 3}, compact]).

marker(T, X, Y) ->
    C = color(T),
    S = "stroke=\"white\" stroke-width=\"1\"",
    case T of
        "full"  -> io_lib:format("<circle cx=\"~.1f\" cy=\"~.1f\" r=\"4\" fill=\"~s\" ~s/>",
                                 [float(X), float(Y), C, S]);
        "imp2D" -> io_lib:format("<rect x=\"~.1f\" y=\"~.1f\" width=\"8\" height=\"8\" fill=\"~s\" ~s/>",
                                 [X - 4.0, Y - 4.0, C, S]);
        "2D"    -> io_lib:format("<polygon points=\"~.1f,~.1f ~.1f,~.1f ~.1f,~.1f\" fill=\"~s\" ~s/>",
                                 [float(X), Y - 5.0, X - 5.0, Y + 4.0, X + 5.0, Y + 4.0, C, S]);
        "line"  -> io_lib:format("<polygon points=\"~.1f,~.1f ~.1f,~.1f ~.1f,~.1f ~.1f,~.1f\" "
                                 "fill=\"~s\" ~s/>",
                                 [float(X), Y - 5.0, X + 5.0, float(Y), float(X), Y + 5.0,
                                  X - 5.0, float(Y), C, S])
    end.

line(X1, Y1, X2, Y2, Color, Width) ->
    io_lib:format("<line x1=\"~.1f\" y1=\"~.1f\" x2=\"~.1f\" y2=\"~.1f\" stroke=\"~s\" "
                  "stroke-width=\"~p\"/>",
                  [float(X1), float(Y1), float(X2), float(Y2), Color, Width]).

text(X, Y, Str, Anchor, Size, Color) ->
    io_lib:format("<text x=\"~.1f\" y=\"~.1f\" text-anchor=\"~s\" font-size=\"~p\" "
                  "fill=\"~s\">~s</text>", [float(X), float(Y), Anchor, Size, Color, Str]).

color("full")  -> "#2a78d6";
color("imp2D") -> "#eb6834";
color("2D")    -> "#1baf7a";
color("line")  -> "#eda100".

label("full")  -> "Full";
label("imp2D") -> "Imperfect 2D";
label("2D")    -> "2D grid";
label("line")  -> "Line".

%% ---------------------------------------------------------------------
%% Data helpers.
%% ---------------------------------------------------------------------
read_csv(Name) ->
    {ok, Bin} = file:read_file(filename:join(exp_dir(), Name)),
    Lines = [string:trim(L) || L <- string:split(binary_to_list(Bin), "\n", all)],
    [string:split(L, ",", all) || L <- Lines, L =/= ""].

num(S) ->
    try list_to_integer(S)
    catch error:badarg ->
            try list_to_float(S)
            catch error:badarg -> list_to_float(fix_float(S))
            end
    end.

%% Erlang wants a digit after the dot: "1e-5" / "2.e-3" -> "1.0e-5" / "2.0e-3".
fix_float(S) ->
    case string:split(S, "e") of
        [M, E] -> fix_mantissa(M) ++ "e" ++ E;
        [M]    -> fix_mantissa(M)
    end.

fix_mantissa(M) ->
    case lists:member($., M) of
        true  -> case lists:last(M) of $. -> M ++ "0"; _ -> M end;
        false -> M ++ ".0"
    end.

%% Median of the values for each x, sorted by x.
medians(Pairs) ->
    Xs = lists:usort([X || {X, _} <- Pairs]),
    [{X, median([Y || {X2, Y} <- Pairs, X2 == X])} || X <- Xs].

median(Vals) ->
    S = lists:sort(Vals),
    N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

%% ---------------------------------------------------------------------
%% Files and PDF.
%% ---------------------------------------------------------------------
exp_dir() ->
    filename:dirname(filename:absname(escript:script_name())).

save(Name, Svg) ->
    Dir = filename:join(exp_dir(), "figures"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, Name ++ ".svg"), Svg).

build_pdf(Template, PdfName) ->
    {ok, Html} = file:read_file(filename:join(exp_dir(), Template)),
    Page = inline_figures(binary_to_list(Html)),
    Tmp = filename:join(exp_dir(), "build_" ++ Template),
    ok = file:write_file(Tmp, Page),
    Pdf = filename:join(filename:dirname(exp_dir()), PdfName),
    case filelib:is_file(?CHROME) of
        true ->
            Port = open_port({spawn_executable, ?CHROME},
                             [{args, ["--headless", "--disable-gpu", "--no-pdf-header-footer",
                                      "--print-to-pdf=" ++ Pdf, "file://" ++ Tmp]},
                              exit_status, stderr_to_stdout]),
            wait_port(Port),
            file:delete(Tmp),
            io:format("wrote ~s~n", [Pdf]);
        false ->
            io:format("Chrome not found. Open ~s in a browser and print it to PDF.~n", [Tmp])
    end.

wait_port(Port) ->
    receive
        {Port, {exit_status, _}} -> ok;
        {Port, _} -> wait_port(Port)
    end.

inline_figures(Html) ->
    case string:split(Html, "{{fig:") of
        [Before, Rest] ->
            [Name, After] = string:split(Rest, "}}"),
            {ok, Svg} = file:read_file(filename:join([exp_dir(), "figures", Name ++ ".svg"])),
            Before ++ "<div class=\"fig\">" ++ binary_to_list(Svg) ++ "</div>"
                ++ inline_figures(After);
        [All] ->
            All
    end.
