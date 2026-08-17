#!/usr/bin/env escript
%% -*- erlang -*-
%% =====================================================================
%% alloc_diag.escript - EMQX allocator memory diagnostic.
%%
%% Fetches allocator data from a running EMQX node over RPC and reports:
%%   * how much multiblock-carrier memory is still held by each allocator
%%     instance ("home") vs. ABANDONED into the carrier pool (free blocks
%%     marked re-usable via madvise(MADV_FREE)),
%%   * OS RSS vs. live bytes,
%%   * suggested vm.args based on the detected OTP version.
%%
%% Run via EMQX's OWN erts (see alloc_diag.sh wrapper). The client must
%% use -epmd_module ekka_epmd because EMQX registers its node with
%% ekka_epmd (deterministic name->port), not the OS epmd.
%%
%% Usage:
%%   alloc_diag.escript <node> <cookie> [--verbose]
%% =====================================================================

-record(state, {otp, has_acful, home, pool, pool_carriers, pool_used,
                rss, live, total, cgroup}).

main(Args) ->
    {Target, Cookie, Verbose, TrendSec, Watch, PoolSizes} = parse_args(Args),
    {ok, _} = net_kernel:start([client_name(Target), longnames]),
    erlang:set_cookie(node(), list_to_atom(Cookie)),
    case net_adm:ping(Target) of
        pong -> ok;
        pang ->
            io:format(standard_error,
                      "~nERROR: cannot connect to ~p~n"
                      "  check node name / cookie (hint: run 'emqx_ctl status' to"
                      " see the real node name)~n", [Target]),
            halt(1)
    end,
    OtpMajor = otp_major(Target),
    Types = [binary_alloc, ets_alloc, eheap_alloc, std_alloc, sl_alloc,
             ll_alloc, driver_alloc, fix_alloc, literal_alloc],
    print_header(Target, OtpMajor),
    io:format("  type           home         home_cr  pool_cr  pool        "
              "pool_used   marked_reclaimable~n"),
    io:format("  --------------------------------------------------"
              "------------------------------------------------~n"),
    Rs = [diag(Target, T, Verbose) || T <- Types],
    State = summarize(Target, Rs, OtpMajor),
    print_alloc_config(Target, Types),
    print_pool_reuse(Target, Types),
    case Watch of
        {Interval, Count} -> pool_watch(Target, Types, Interval, Count);
        undefined ->
            case TrendSec of
                undefined -> ok;
                Sec -> pool_trend(Target, Types, Sec)
            end
    end,
    case PoolSizes of
        false -> ok;
        {HistStart, HistWidth} -> pool_sizes(Target, Types, HistStart, HistWidth)
    end,
    print_recommendations(State),
    halt(0).

%% ---------------------------------------------------------------------
%% CLI
%% ---------------------------------------------------------------------
parse_args([NodeStr, Cookie]) ->
    {list_to_atom(NodeStr), Cookie, false, undefined, undefined, false};
parse_args([NodeStr, Cookie, "--verbose"]) ->
    {list_to_atom(NodeStr), Cookie, true, undefined, undefined, false};
parse_args([NodeStr, Cookie, "--trend", Sec]) ->
    {list_to_atom(NodeStr), Cookie, false, list_to_integer(Sec), undefined, false};
parse_args([NodeStr, Cookie, "--verbose", "--trend", Sec]) ->
    {list_to_atom(NodeStr), Cookie, true, list_to_integer(Sec), undefined, false};
parse_args([NodeStr, Cookie, "--watch", Interval, Count]) ->
    {list_to_atom(NodeStr), Cookie, false, undefined,
     {list_to_integer(Interval), list_to_integer(Count)}, false};
parse_args([NodeStr, Cookie, "--verbose", "--watch", Interval, Count]) ->
    {list_to_atom(NodeStr), Cookie, true, undefined,
     {list_to_integer(Interval), list_to_integer(Count)}, false};
parse_args([NodeStr, Cookie, "--pool-sizes"]) ->
    {list_to_atom(NodeStr), Cookie, false, undefined, undefined, {512, 14}};
parse_args([NodeStr, Cookie, "--pool-sizes", PoolSpec]) ->
    {list_to_atom(NodeStr), Cookie, false, undefined, undefined,
     parse_pool_sizes(PoolSpec)};
parse_args([NodeStr, Cookie, "--verbose", "--pool-sizes"]) ->
    {list_to_atom(NodeStr), Cookie, true, undefined, undefined, {512, 14}};
parse_args([NodeStr, Cookie, "--verbose", "--pool-sizes", PoolSpec]) ->
    {list_to_atom(NodeStr), Cookie, true, undefined, undefined,
     parse_pool_sizes(PoolSpec)};
parse_args(_) ->
    io:format(standard_error,
              "usage: alloc_diag.escript <node> <cookie> [--verbose]~n"
              "                    [--trend <sec> | --watch <interval> <count>~n"
              "                     | --pool-sizes [<hist_start>[,<hist_width>]]]~n",
              []),
    halt(1).

parse_pool_sizes(Spec) ->
    case string:tokens(Spec, ",") of
        [HistStart] ->
            {list_to_integer(HistStart), 14};
        [HistStart, HistWidth] ->
            {list_to_integer(HistStart), list_to_integer(HistWidth)};
        _ ->
            io:format(standard_error,
                      "invalid --pool-sizes argument (expected <hist_start>"
                      " or <hist_start>,<hist_width>): ~s~n", [Spec]),
            halt(1)
    end.

%% unique short-lived node name, same host as the target (longnames)
client_name(Target) ->
    [_Name, Host] = string:split(atom_to_list(Target), "@", all),
    list_to_atom("remsh_allocdiag_" ++ os:getpid() ++ "@" ++ Host).

print_header(Target, OtpMajor) ->
    Emqx = case rpc:call(Target, emqx_sys, version, [], 10000) of
               V when is_list(V); is_binary(V) -> V;
               _ -> "?"
           end,
    io:format("~nemqx ~s (OTP ~p) node ~p~n~n",
              [Emqx, case OtpMajor of 0 -> "?"; M -> M end, Target]).

%% ---------------------------------------------------------------------
%% OTP version / feature detection on the target
%% ---------------------------------------------------------------------
otp_major(Node) ->
    case rpc:call(Node, erlang, system_info, [otp_release], 10000) of
        Rel when is_list(Rel) ->
            case string:to_integer(Rel) of
                {Major, _} when is_integer(Major) -> Major;
                _ -> 0
            end;
        _ -> 0
    end.

has_acful(Node) ->
    case rpc:call(Node, erlang, system_info, [{allocator, binary_alloc}], 10000) of
        L when is_list(L) ->
            lists:any(fun({instance, _, Props}) ->
                              lists:keymember(acful, 1,
                                              proplists:get_value(options, Props, []))
                      end, L);
        _ -> false
    end.

%% ---------------------------------------------------------------------
%% Helpers (parse erlang:system_info({allocator, T}) terms)
%% ---------------------------------------------------------------------
%% used bytes in a blocks list: pool {size,S} / mbcs {size,Cur,_,_}
blksz(Blks) ->
    lists:sum([case lists:keyfind(size, 1, Info) of
                   {size, S} when is_integer(S) -> S;
                   {size, S, _, _} -> S;
                   _ -> 0
               end || {_, Info} <- Blks]).

%% current carriers_size: mbcs/sbcs 4-tuple / pool 2-tuple
csz(L) ->
    case lists:keyfind(carriers_size, 1, L) of
        {carriers_size, C, _, _} -> C;
        {carriers_size, C} -> C;
        _ -> 0
    end.

%% number of pooled carriers (mbcs_pool: 2-tuple {carriers, N})
pcnt(L) ->
    case lists:keyfind(carriers, 1, L) of
        {carriers, N} -> N;
        _ -> 0
    end.

%% number of home (non-pooled) carriers (mbcs/sbcs: 4-tuple {carriers,C,_,_})
hcnt(L) ->
    case lists:keyfind(carriers, 1, L) of
        {carriers, C, _, _} -> C;
        _ -> 0
    end.

mb(B) when is_integer(B) -> B / 1048576;
mb(_) -> 0.0.

%% carrier-pool counter: stored as {Key, Giga, Low} where Giga = CC div 10^9
%% and Low = CC rem 10^9 (see ERTS_ALC_CC_GIGA_VAL / ONE_GIGA in
%% erl_alloc_util.c). Combine with * 1000000000, NOT bsl 30.
cc({_, G, L}) when is_integer(G), is_integer(L) -> G * 1000000000 + L;
cc(_) -> 0.

%% ---------------------------------------------------------------------
%% One allocator type
%% ---------------------------------------------------------------------
diag(Target, Type, Verbose) ->
    case rpc:call(Target, erlang, system_info, [{allocator, Type}], 30000) of
        {badrpc, Reason} ->
            io:format("  ~-14s rpc error: ~p~n", [Type, Reason]),
            {Type, 0, 0, 0, 0, 0};
        false ->
            io:format("  ~-14s disabled~n", [Type]),
            {Type, 0, 0, 0, 0, 0};
        All when is_list(All) ->
            {Home, HC, Pools} =
                lists:foldl(fun({instance, Ix, Props}, {H, Hc, Ps}) ->
                                    Mb = proplists:get_value(mbcs, Props, []),
                                    Sb = proplists:get_value(sbcs, Props, []),
                                    H0 = csz(Mb) + csz(Sb),
                                    Hc0 = hcnt(Mb) + hcnt(Sb),
                                    case proplists:get_value(mbcs_pool, Props) of
                                        undefined ->
                                            maybe_instance(Verbose, Ix, H0),
                                            {H + H0, Hc + Hc0, Ps};
                                        Pl ->
                                            N0 = pcnt(Pl),
                                            S0 = csz(Pl),
                                            U0 = blksz(proplists:get_value(blocks, Pl, [])),
                                            maybe_instance(Verbose, Ix, H0, N0, S0, U0),
                                            {H + H0, Hc + Hc0, [{N0, S0, U0} | Ps]}
                                    end
                            end, {0, 0, []}, All),
            {N, S, U} = lists:foldl(fun({A, B, C}, {Nn, Ss, Uu}) ->
                                            {Nn + A, Ss + B, Uu + C}
                                    end, {0, 0, 0}, Pools),
            io:format("  ~-14s home=~8.2fMB  home_cr=~4w  pool_cr=~4w  "
                      "pool=~8.2fMB  pool_used=~8.2fMB  "
                      "marked_reclaimable=~8.2fMB~n",
                      [Type, mb(Home), HC, N, mb(S), mb(U), mb(S - U)]),
            {Type, Home, HC, N, S, U}
    end.

maybe_instance(false, _Ix, _H0) -> ok;
maybe_instance(true, Ix, H0) ->
    io:format("      ~p: home=~8.2fMB  (pool disabled)~n", [Ix, mb(H0)]).

maybe_instance(false, _Ix, _H0, _N0, _S0, _U0) -> ok;
maybe_instance(true, Ix, H0, N0, S0, U0) ->
    io:format("      ~p: home=~8.2fMB  pool_carriers=~5w  "
              "pool=~8.2fMB  pool_used=~8.2fMB~n",
              [Ix, mb(H0), N0, mb(S0), mb(U0)]).

%% ---------------------------------------------------------------------
%% Carrier-pool reuse counters — this is the direct signal for the
%% "size mismatch" diagnosis (pool holds abandoned carriers whose free
%% blocks are too small for new demand, so reuse fails and new carriers
%% get mmap'ed => RSS keeps rising).
%%
%%   fetch       = a pooled carrier WAS reused (good)
%%   skip_size   = pooled carrier found, but its largest free block was
%%                 smaller than the request (size mismatch)
%%   fail_pooled = gave up searching the instance's own pool
%%   fail        = total pool-allocation failures => a NEW carrier is
%%                 created => RSS grows
%% ---------------------------------------------------------------------
pool_counters(Target, Type) ->
    case rpc:call(Target, erlang, system_info, [{allocator, Type}], 30000) of
        All when is_list(All) ->
            Sum = fun(Key) ->
                          lists:foldl(
                            fun({instance, _, Props}, Acc) ->
                                    case proplists:get_value(mbcs_pool, Props) of
                                        undefined -> Acc;
                                        Pl -> Acc + cc(lists:keyfind(Key, 1, Pl))
                                    end
                            end, 0, All)
                  end,
            #{fetch => Sum(fetch), skip_size => Sum(skip_size),
              fail_pooled => Sum(fail_pooled), fail => Sum(fail)};
        _ ->
            #{fetch => 0, skip_size => 0, fail_pooled => 0, fail => 0}
    end.

print_pool_reuse(Target, Types) ->
    io:format("~n=== carrier-pool reuse / size-mismatch diagnosis ===~n"),
    io:format("  type           fetch        skip_size    fail_pooled  "
              "fail         verdict~n"),
    io:format("  ------------------------------------------------------"
              "-----------------------------------~n"),
    lists:foreach(fun(T) -> print_one_reuse(Target, T) end, Types),
    io:format("~n"
              "  fetch       pooled carrier reused (good)~n"
              "  skip_size   pooled carrier too SMALL for the request "
              "(= size mismatch)~n"
              "  fail_pooled gave up searching own pool (no carrier fit)~n"
              "  fail        total pool failure => new carrier => RSS grows~n"
              "~n"
              "  Read: if skip_size + fail >> fetch, the pool's free blocks are~n"
              "  mostly too small for new demand -> size mismatch. If fetch ~n"
              "  dominates, the pool is being reused normally and RSS growth is~n"
              "  live-set growth instead.~n").

print_one_reuse(Target, Type) ->
    C = pool_counters(Target, Type),
    F = maps:get(fetch, C, 0),
    Sk = maps:get(skip_size, C, 0),
    Fp = maps:get(fail_pooled, C, 0),
    Fa = maps:get(fail, C, 0),
    io:format("  ~-14s ~-12w ~-12w ~-12w ~-12w ~s~n",
              [Type, F, Sk, Fp, Fa, verdict(F, Sk, Fp, Fa)]).

verdict(F, Sk, Fp, Fa) ->
    Reused = F,
    Missed = Sk + Fp + Fa,
    if
        Reused + Missed == 0 -> "no pool activity";
        Reused > Missed -> "pool reused (not size mismatch)";
        Missed > Reused -> "SIZE MISMATCH (blocks too small)";
        true -> "mixed reuse"
    end.

%% ---------------------------------------------------------------------
%% Allocator configuration (strategy, abandon thresholds, carrier sizes).
%% Note: instance 0 is the pool-disabled main instance (acul=0), so read
%% options from a non-main instance to get the effective values.
%% ---------------------------------------------------------------------
print_alloc_config(Target, Types) ->
    io:format("~n=== allocator configuration ===~n"),
    io:format("  type           as         acul acnl acfml sbct    "
              "smbcs   lmbcs   atags cp~n"),
    io:format("  ------------------------------------------------------"
              "--------------------------------~n"),
    lists:foreach(fun(T) -> config_one(Target, T) end, Types),
    io:format("~n"
              "  as    allocation strategy (aoffcbf = address-ordered first fit~n"
              "        carriers + best-fit blocks)~n"
              "  acul  abandon carrier utilization limit (%)~n"
              "  acnl  max carriers retained in the pool~n"
              "  acfml min free-block size for a carrier to be abandoned~n"
              "  sbct  single-block-carrier threshold (blocks >= this go to SBC)~n"
              "  smbcs/lmbcs  smallest / largest multiblock carrier size~n"
              "  cp    carrier pool enabled for this allocator (dash = off)~n"
              "  min_block_size is strategy-internal, NOT exposed (aoff approx 48-56 B)~n").

config_one(Target, Type) ->
    case rpc:call(Target, erlang, system_info, [{allocator, Type}], 30000) of
        All when is_list(All) ->
            Props = case [P || {instance, Ix, P} <- All, Ix > 0] of
                        [P1 | _] -> P1;
                        [] -> case All of [{instance, _, P0} | _] -> P0; [] -> [] end
                    end,
            Opts = proplists:get_value(options, Props, []),
            G = fun(K, D) -> proplists:get_value(K, Opts, D) end,
            io:format("  ~-14s ~-9s ~-4w ~-4w ~-5w ~-7s ~-7s ~-7s ~-5s ~s~n",
                      [Type, sval(G(as, undefined)), G(acul, 0), G(acnl, 0),
                       G(acfml, 0), fmt_bytes(G(sbct, 0)), fmt_bytes(G(smbcs, 0)),
                       fmt_bytes(G(lmbcs, 0)), sval(G(atags, false)),
                       sval(G(cp, undefined))]);
        _ -> ok
    end.

%% string form for config atoms/booleans (undefined -> "-")
sval(undefined) -> "-";
sval(A) when is_atom(A) -> atom_to_list(A);
sval(X) when is_integer(X) -> integer_to_list(X);
sval(X) -> lists:flatten(io_lib:format("~w", [X])).

%% Two-sample diff: is the mismatch happening NOW (ongoing), or just a
%% historical one-time pileup?
pool_trend(Target, Types, Sec) ->
    io:format("~n=== size-mismatch trend (delta over ~w s) ===~n", [Sec]),
    Snap = fun() -> [{T, pool_counters(Target, T)} || T <- Types] end,
    S1 = Snap(),
    timer:sleep(Sec * 1000),
    S2 = Snap(),
    io:format("  type           d(skip_size) d(fail_pooled) d(fail)    d(fetch)~n"),
    io:format("  -----------------------------------------------------------~n"),
    lists:foreach(
      fun(T) ->
              {_, C1} = lists:keyfind(T, 1, S1),
              {_, C2} = lists:keyfind(T, 1, S2),
              D = fun(K) -> maps:get(K, C2, 0) - maps:get(K, C1, 0) end,
              io:format("  ~-14s ~-12w ~-13w ~-12w ~-12w~n",
                        [T, D(skip_size), D(fail_pooled), D(fail), D(fetch)])
      end, Types),
    io:format("~n"
              "  If d(skip_size) + d(fail) keeps rising while d(fetch) stays~n"
              "  near zero, the mismatch is ONGOING and drives RSS up. If all~n"
              "  deltas are about 0, the pool is just a historical pileup.~n").

%% Repeated sampling for a FLUCTUATING (non-monotonic) RSS. The counters are
%% cumulative/monotonic, so a single two-sample diff can land in a quiet
%% trough and under-report an ongoing mismatch. --watch samples N times over
%% several fluctuation cycles and reports:
%%   * total deltas over the whole window (last - first, since monotonic),
%%   * "active" = how many intervals saw a pool size-mismatch, and
%%   * the net RSS change, so the mismatch can be correlated with the
%%     rising-trend (not just one spike).
pool_watch(Target, Types, Interval, Count) ->
    io:format("~n=== size-mismatch watch (interval=~w s, ~w samples) ===~n",
              [Interval, Count]),
    Rss0 = target_rss(Target),
    Snaps = [snapshot(Target, Types)
             | [begin
                    timer:sleep(Interval * 1000),
                    snapshot(Target, Types)
                end || _ <- lists:seq(1, Count)]],
    RssN = target_rss(Target),
    io:format("  type           d(skip_size) d(fail_pooled) d(fail)    "
              "d(fetch)    active  verdict~n"),
    io:format("  ------------------------------------------------------"
              "-----------------------------------~n"),
    lists:foreach(fun(T) -> watch_type(T, Snaps, Count) end, Types),
    case {Rss0, RssN} of
        {A, B} when is_integer(A), is_integer(B) ->
            io:format("~n  RSS: ~8.2fMB -> ~8.2fMB  (~8.2fMB over ~w s)~n",
                      [mb(A), mb(B), mb(B - A), Interval * Count]);
        _ -> ok
    end,
    io:format("~n"
              "  active = intervals (of ~w) that saw a pool size-mismatch.~n"
              "  Sustained mismatch across fluctuation cycles => active is high~n"
              "  AND d(skip_size)+d(fail) keep growing while d(fetch) stays low.~n",
              [Count]).

snapshot(Target, Types) ->
    [{T, pool_counters(Target, T)} || T <- Types].

watch_type(T, Snaps, Count) ->
    Maps = [case lists:keyfind(T, 1, S) of {_, M} -> M end || S <- Snaps],
    %% consecutive pairs (N-1 pairs): zip first N-1 with last N-1 elements
    Pairs = lists:zip(lists:sublist(Maps, length(Maps) - 1), tl(Maps)),
    Deltas = [{maps:get(skip_size, C, 0) - maps:get(skip_size, P, 0),
               maps:get(fail_pooled, C, 0) - maps:get(fail_pooled, P, 0),
               maps:get(fail, C, 0) - maps:get(fail, P, 0),
               maps:get(fetch, C, 0) - maps:get(fetch, P, 0)}
              || {P, C} <- Pairs],
    {DSk, DFp, DFa, DFe} =
        lists:foldl(fun({A, B, C, D}, {A0, B0, C0, D0}) ->
                            {A0 + A, B0 + B, C0 + C, D0 + D}
                    end, {0, 0, 0, 0}, Deltas),
    Active = length([1 || {A, _, C, _} <- Deltas, A + C > 0]),
    io:format("  ~-14s ~-12w ~-13w ~-12w ~-12w ~w/~w    ~s~n",
              [T, DSk, DFp, DFa, DFe, Active, Count,
               verdict(DFe, DSk, DFp, DFa)]).

%% ---------------------------------------------------------------------
%% Abandoned-pool free-block size histogram (via instrument:carriers/1).
%% Tells you WHAT SIZE the pooled free blocks are, and whether they are
%% all the same size (one histogram slot dominating) or spread out.
%% log2-bucketed, hist_start=512 B / hist_width=14 by default (~doubling).
%% ---------------------------------------------------------------------
pool_sizes(Target, Types, HistStart, HistWidth) ->
    io:format("~n=== abandoned-pool free-block size distribution "
              "(hist_start=~w B, hist_width=~w) ===~n", [HistStart, HistWidth]),
    case rpc:call(Target, instrument, carriers,
                  [#{histogram_start => HistStart,
                     histogram_width => HistWidth}], 60000) of
        {ok, {_, Carriers}} ->
            print_pool_hist(HistStart, Carriers, Types);
        {error, Reason} ->
            io:format("  instrument:carriers/1 failed: ~p~n", [Reason]);
        {badrpc, Reason} ->
            io:format("  instrument:carriers/1 unavailable on target: ~p~n", [Reason]),
            io:format("  (needs the 'tools' OTP app in the release; otherwise run~n"
                      "   the erts_internal:gather_carrier_info/1 snippet manually~n"
                      "   in a remsh shell)~n");
        Other ->
            io:format("  unexpected result: ~p~n", [Other])
    end.

print_pool_hist(HistStart, Carriers, Types) ->
    %% aggregate the free-block histogram of InPool carriers, per allocator
    Agg = lists:foldl(
            fun({A, true, _Sz, _Unsc, _Blk, FH}, Acc) ->
                    Zero = erlang:make_tuple(tuple_size(FH), 0),
                    Old  = maps:get(A, Acc, Zero),
                    Sum  = list_to_tuple([element(I, Old) + element(I, FH)
                                          || I <- lists:seq(1, tuple_size(FH))]),
                    maps:put(A, Sum, Acc);
               (_, Acc) -> Acc
            end, #{}, Carriers),
    case lists:any(fun(A) -> maps:is_key(A, Agg) end, Types) of
        false ->
            io:format("  (no carriers are currently in the pool)~n");
        true ->
            HistWidth = case maps:values(Agg) of
                            [] -> 0;
                            [S | _] -> tuple_size(S)
                        end,
            io:format("  (log2-bucketed, hist_start=~w B, hist_width=~w; "
                      "each slot doubles in size; last slot is open-ended)~n",
                      [HistStart, HistWidth]),
            lists:foreach(
              fun(A) ->
                      case maps:get(A, Agg, undefined) of
                          undefined -> ok;
                          Sum ->
                              TupleSize = tuple_size(Sum),
                              Total = lists:sum(tuple_to_list(Sum)),
                              io:format("~n  ~-14s ~w free block~s in pool:~n",
                                        [A, Total, plural(Total)]),
                              lists:foreach(
                                fun(I) ->
                                        N = element(I, Sum),
                                        if N > 0 ->
                                               io:format("    ~10s  ~w block~s~n",
                                                         [hist_label(HistStart, I, TupleSize),
                                                          N, plural(N)]);
                                           true -> ok
                                        end
                                end, lists:seq(1, TupleSize))
                      end
              end, Types)
    end.

%% Print the bucket label.  Non-last slots are shown by their upper bound;
%% the last slot is the open-ended overflow bucket, so "128 B" would be
%% misleading there (it actually means ">= 64 B" when hist_width=3).
hist_label(_HistStart, _I, TupleSize) when TupleSize =< 2 ->
    "all";
hist_label(HistStart, I, TupleSize) when I =:= TupleSize ->
    ">= " ++ fmt_bytes(HistStart bsl (TupleSize - 2));
hist_label(HistStart, I, _TupleSize) ->
    fmt_bytes(HistStart bsl (I - 1)).

plural(1) -> "";
plural(_) -> "s".

fmt_bytes(B) when B >= 1073741824 -> integer_to_list(B div 1073741824) ++ " GB";
fmt_bytes(B) when B >= 1048576    -> integer_to_list(B div 1048576) ++ " MB";
fmt_bytes(B) when B >= 1024       -> integer_to_list(B div 1024) ++ " KB";
fmt_bytes(B)                      -> integer_to_list(B) ++ " B".

%% ---------------------------------------------------------------------
%% OS RSS / cgroup on the target (robust across Linux/BusyBox/macOS)
%% ---------------------------------------------------------------------
target_pid(Node) ->
    rpc:call(Node, os, getpid, [], 10000).

target_rss(Node) ->
    Pid = target_pid(Node),
    case vmrss(rpc:call(Node, os, cmd, ["cat /proc/" ++ Pid ++ "/status"], 10000)) of
        {ok, B} -> B;
        error ->
            case psrss(rpc:call(Node, os, cmd, ["ps -o rss= -p " ++ Pid], 10000)) of
                {ok, B2} -> B2;
                error -> undefined
            end
    end.

vmrss(Out) when is_list(Out) ->
    Toks = [string:tokens(L, " \t") || L <- string:tokens(Out, "\n")],
    case [KB || ["VmRSS:", KB | _] <- Toks] of
        [KB | _] -> {ok, list_to_integer(KB) * 1024};
        [] -> error
    end;
vmrss(_) -> error.

psrss(Out) when is_list(Out) ->
    case catch list_to_integer(string:trim(Out)) of
        KB when is_integer(KB), KB >= 0 -> {ok, KB * 1024};
        _ -> error
    end;
psrss(_) -> error.

cgroup_limit(Node) ->
    Out = rpc:call(Node, os, cmd,
                   ["cat /sys/fs/cgroup/memory.max 2>/dev/null || "
                    "cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null"],
                   10000),
    case string:trim(Out) of
        "max" -> undefined;
        "" -> undefined;
        S -> case catch list_to_integer(S) of
                 N when is_integer(N), N > 0 -> N;
                 _ -> undefined
             end
    end.

%% ---------------------------------------------------------------------
%% Overall summary
%% ---------------------------------------------------------------------
summarize(Target, Rs, OtpMajor) ->
    {H, HC, N, S, U} =
        lists:foldl(fun({_, H0, HC0, N0, S0, U0}, {H1, HC1, N1, S1, U1}) ->
                            {H1 + H0, HC1 + HC0, N1 + N0, S1 + S0, U1 + U0}
                    end, {0, 0, 0, 0, 0}, Rs),
    Mem = rpc:call(Target, erlang, memory, [], 15000),
    Live = proplists:get_value(binary, Mem, 0),
    Total = proplists:get_value(total, Mem, 0),
    Rss = target_rss(Target),
    Cg = cgroup_limit(Target),
    io:format("~n=== overall ===~n"),
    io:format("  total carriers:              ~w  (home=~w, pool=~w)~n",
              [HC + N, HC, N]),
    io:format("  VM retained (home+pool):     ~8.2fMB~n", [mb(H + S)]),
    io:format("    home (not marked):         ~8.2fMB~n", [mb(H)]),
    io:format("    pool total (abandoned):    ~8.2fMB   (~w carriers)~n",
              [mb(S), N]),
    io:format("    pool used (still live):    ~8.2fMB~n", [mb(U)]),
    io:format("    pool marked-reclaimable:   ~8.2fMB   (madvise(MADV_FREE))~n",
              [mb(S - U)]),
    io:format("  OS VmRSS:                    ~8.2fMB~n",
              [case Rss of undefined -> 0.0; B -> mb(B) end]),
    io:format("  erlang:memory(binary) live:  ~8.2fMB~n", [mb(Live)]),
    io:format("  erlang:memory(total):        ~8.2fMB~n", [mb(Total)]),
    case Cg of
        undefined -> ok;
        _ -> io:format("  cgroup memory limit:        ~8.2fMB~n", [mb(Cg)])
    end,
    #state{otp = OtpMajor, has_acful = has_acful(Target),
           home = H, pool = S, pool_carriers = N, pool_used = U,
           rss = Rss, live = Live, total = Total, cgroup = Cg}.

%% ---------------------------------------------------------------------
%% Recommendations
%% ---------------------------------------------------------------------
print_recommendations(#state{} = S) ->
    io:format("~n=== recommendation (based on detected OTP ~p) ===~n",
              [case S#state.otp of 0 -> "?"; M -> M end]),
    [io:format("  ~ts~n", [unicode:characters_to_binary(L)]) || L <- recommend(S)],
    io:format("~n").

recommend(S) ->
    Otp = S#state.otp,
    PoolBig = S#state.pool > S#state.home,
    RssHi = case {S#state.rss, S#state.live} of
                {R, L} when is_integer(R), is_integer(L), L > 0 -> R > L * 2;
                _ -> false
            end,
    [oheader(Otp)]
    ++ feature_note(Otp, S#state.has_acful)
    ++ case PoolBig andalso RssHi of
           true -> [os_rss_mark(Otp)];
           false -> [os_rss_low()]
       end
    ++ (case S#state.pool of
            0 ->
                ["NOTE: no carriers are abandoned into the pool, so free blocks"
                 " are NOT marked re-usable. Check that carrier migration is on"
                 " (acul > 0, not +M<i>t false / +M<i>as bf) and that per-carrier"
                 " utilization actually drops below acul%."];
            _ -> []
        end)
    ++ ["VM args: add +M<i>as aoffcbf explicitly to document intent (it is"
        " already the effective default when carrier migration is on)."]
    ++ ["VM args: tune +M<i>acul (default 60) - lower = less carrier churn but"
        " more memory retained; higher = more aggressive abandon/marking."].

oheader(0) ->
    "(OTP release could not be detected on the target node.)";
oheader(Otp) ->
    "This node runs OTP " ++ integer_to_list(Otp)
    ++ " (EMQX 4.4.x = OTP 24; 5.x/6.x may vary - always check, never assume).".

%% HasAcful = 'acful' shows up in the allocator options -> OTP >= 26.
feature_note(Otp, true) when Otp >= 27 ->
    ["+M<i>acful de is available (default is 0 = free blocks of pooled"
     " carriers are NOT marked re-usable). If RSS stays high while usage is low,"
     " set +M<i>acful de to enable marking.",
     "+Mumadtn true is available on OTP 27.3.4.x-later / 28 (OTP-19739): switches"
     " madvise(MADV_FREE) to MADV_DONTNEED so discarded pages are returned to the"
     " OS eagerly. On older OTP 27.x the option is absent."];
feature_note(_Otp, true) ->
    ["+M<i>acful de is available (default is 0 = no marking). +Mumadtn is NOT"
     " available here - RSS from abandoned pages only drops under memory pressure."];
feature_note(_Otp, false) ->
    ["+M<i>acful and +Mumadtn are NOT available. The VM uses madvise(MADV_FREE):"
     " abandoned free blocks are marked re-usable but only reclaimed by the kernel"
     " under memory pressure - RSS will stay high until then. The only way to make"
     " RSS drop eagerly is to upgrade to OTP 27.3.4.x-later/28 and use"
     " +Mumadtn true."].

os_rss_mark(Otp) ->
    "OBSERVED: RSS >> live binary bytes and a large share of the pool is"
    " marked-reclaimable - this is MADV_FREE laziness, not a leak. The kernel"
    " will reclaim those pages under memory pressure."
    ++ case Otp >= 27 of
           true -> " If you need RSS to drop immediately, add: +Mumadtn true";
           false -> " On this OTP you cannot force eager return; monitor or upgrade."
       end.

os_rss_low() ->
    "OBSERVED: RSS is not far above live usage, or the pool is small - the"
    " allocator is not retaining much reclaimable memory right now.".
