%%
%%    Tracer
%%    Copyright (C) 2016 - Guillaume Bour
%%
%%    This program is free software: you can redistribute it and/or modify
%%    it under the terms of the GNU General Public License as published by
%%    the Free Software Foundation, either version 3 of the License, or
%%    (at your option) any later version.
%%
%%    This program is distributed in the hope that it will be useful,
%%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%    GNU General Public License for more details.
%%
%%    You should have received a copy of the GNU General Public License
%%    along with this program.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(tracer_collector).
-author("Guillaume Bour <guillaume@bour.cc>").
-behaviour(gen_fsm).


% public API
-export([start/3, stop/0]).
% gen_fsm funs
-export([start_link/0, init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).
% internal funs
-export([idle/2, running/2]).

-record(state, {
    fh,
    interval,
    extra_metrics,

    start_ts,
    count
 }).

-type tracer_extra_metrics() :: [{process, atom()} | {exo, atom(), atom()}].

-spec start_link() -> {ok, pid()} | ignore | {error, any()}.
start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_) ->
    {ok, idle, #state{}}.

%%
%% PUBLIC API
%%

-spec start(string(), integer(), tracer_extra_metrics()) -> ok.
start(Path, Interval, ExtraMetrics) ->
    gen_fsm:send_event(?MODULE, {start, Path, Interval, ExtraMetrics}).

-spec stop() -> ok.
stop() ->
    gen_fsm:send_event(?MODULE, stop).


%%
%% INTERNAL CALLBACKS
%%


idle({start, Path, Interval, ExtraMetrics}, _State) ->
    lager:debug("starting"),

    {{Y,M,D},{H,Mn,S}} = calendar:local_time(),
    Date = io_lib:fwrite("~B~2..0B~2..0B~2..0B~2..0B~2..0B", [Y,M,D,H,Mn,S]),
    {ok, Fh} = file:open([Path,$/,"tracer-",Date,".csv"], [write]),
    headers(Fh, ExtraMetrics),

    StartTs = erlang:monotonic_time(),
    collect(Fh, ExtraMetrics, StartTs),

    {next_state, running, #state{interval=Interval, fh=Fh, start_ts=StartTs, count=1,
                                 extra_metrics=ExtraMetrics}, Interval};

idle(_, State) ->
    {next_state, idle, State}.


running(stop, State=#state{fh=Fh}) ->
    lager:debug("stopping"),
    file:close(Fh),

    {next_state, idle, State};

running({start, _,_,_}, State=#state{interval=Interval}) ->
    lager:debug("already started"),
    {next_state, running, State, Interval};

running(timeout, State=#state{interval=Interval, fh=Fh, start_ts=StartTs, count=Cnt,
                              extra_metrics=Extra}) ->
    lager:debug("timeout"),
    collect(Fh, Extra, StartTs),

    %
    %
    Interval2 = Interval - (erlang:convert_time_unit(erlang:monotonic_time() - StartTs, native, milli_seconds)
                         - Cnt*Interval),
    %lager:debug("corrected interval: ~p", [Interval2]),
    {next_state, running, State#state{interval=Interval, count=Cnt+1}, Interval2}.


handle_event(_Event, _StateName, StateData) ->
	lager:debug("event ~p", [_StateName]),
    {stop, error, StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
	lager:debug("syncevent ~p", [_StateName]),
    {stop, error, error, StateData}.

handle_info(_Info, _StateName, StateData) ->
	lager:debug("info ~p", [_StateName]),
    {stop, error, StateData}.

terminate(_Reason, _StateName, _State) ->
    lager:info("session terminate with undefined state: ~p", [_Reason]),
    terminate.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


%%
%% INTERNAL FUNS
%%


-spec headers(file:io_device(), tracer_extra_metrics()) -> ok.
headers(Fh, ExtraMetrics) ->
    file:write(Fh, ["ts;num-procs;run-queue;reduc-procs;reduc-ports"]),
    [ file:write(Fh, [$;,"mem-",str(Name)]) || {Name,_} <- erlang:memory()],

    headers_extra(Fh, ExtraMetrics),
    file:write(Fh, [$\n]),
    ok.

headers_extra( _, []) ->
    ok;
headers_extra(Fh, [{process, Name} | T]) ->
    lists:foreach(fun(Metric) -> file:write(Fh, [$;, str(Name),"-",str(Metric)]) end,
                  [message_queue_len,heap_size,stack_size,reductions]),

    headers_extra(Fh, T);
headers_extra(Fh, [{exo, Name, DataPoint} | T]) ->
    Name1 = string:join([ str(N) || N <- Name], "_"),
    file:write(Fh, [$;, Name1, $-, str(DataPoint)]),

    headers_extra(Fh, T).


-spec collect(file:io_device(), tracer_extra_metrics(), integer()) -> ok.
collect(Fh, ExtraMetrics, StartTs) ->
    file:write(Fh, [
        str(erlang:convert_time_unit(erlang:monotonic_time()-StartTs, native, milli_seconds)),$;,

        str(erlang:system_info(process_count)), $;,
        str(erlang:statistics(run_queue))
    ]),

    {RProc, RPorts} = erlang:statistics(reductions),
    file:write(Fh, [$;, str(RProc), $;, str(RPorts)]),

    [ file:write(Fh, [$;, str(Value)]) || {_, Value} <- erlang:memory() ],

    collect_extra(Fh, ExtraMetrics),
    %erlang:whereis(Name)

    file:write(Fh, [$\n]),
    ok.

collect_extra( _, []) ->
    ok;
collect_extra(Fh, [{process, Name}|T]) ->
    lists:foreach(fun({_, Value}) ->
            file:write(Fh, [$;,str(Value)])
        end,
        erlang:process_info(erlang:whereis(Name),
                            [message_queue_len,heap_size,stack_size,reductions])
    ),

    collect_extra(Fh, T);
collect_extra(Fh, [{exo, Name, DataPoint}|T]) ->
    {ok, [{DataPoint, Value}]} = exometer:get_value(Name, DataPoint),
    file:write(Fh, [$;, str(Value)]),

    collect_extra(Fh, T).


str(Val) when is_float(Val) ->
    erlang:float_to_list(Val);
str(Val) when is_integer(Val) ->
    erlang:integer_to_list(Val);
str(Val) when is_atom(Val) ->
    erlang:atom_to_list(Val).
