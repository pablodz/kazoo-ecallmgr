%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_call_control_manager).

-behaviour(gen_server).

-include("ecallmgr.hrl").

-export([start_link/0]).
-export([start_call_control/1]).

-export([set_control_q_strategy/1]).
-export([set_direct_control_q_strategy/1]).


%% gen_server callbacks
-export([handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ,init/1
        ]).

-type state() :: map().

%% ===================================================================
%% API functions
%% ===================================================================

%%------------------------------------------------------------------------------
%% @doc Starts Server
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_server:start_link({'local', ?MODULE}, ?MODULE, [], []).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init(list()) -> {'ok', state()}.
init(_) ->
    Workers = kz_app_config:get_integer(?APP, [<<"call_control">>, <<"listeners">>], 5),
    QueueStrategy = kz_app_config:get_atom(?APP, [<<"call_control">>, <<"queue_strategy">>], 'private'),
    kz_amqp_channel:requisition(),
    {'ok', #{workers => Workers
            ,queue => set_queue(QueueStrategy)
            ,listeners => #{}
            ,pids => #{}
            ,refs => #{}
            ,channels => #{}
            }}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    lager:debug("unhandled call: ~p from ~p", [_Request, _From]),
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast('init_queues', State) ->
    {'noreply', init_queues(State)};

handle_cast({'call_control_listener_is_ready', Pid, Channel, Queue, Active}, State) ->
    {'noreply', add_listener(Pid, Channel, Queue, Active, State)};

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'kz_amqp_assignment', {'new_channel', Reconnect, Channel}}, State) ->
    {'noreply', handle_canary(Reconnect, Channel, State)};
handle_info({'DOWN', Ref, 'process', Pid, Reason}, State) ->
    {'noreply', handle_down(Pid, Ref, Reason, State)};
handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, #{canary := Channel}) ->
    kz_amqp_channel:release(Channel),
    lager:debug("releasing channel ~p and terminating call control manager : ~p ", [Channel, _Reason]);
terminate(_Reason, _) ->
    lager:debug("terminating call control manager : ~p ", [_Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.


-spec set_queue(atom()) -> kz_term:api_ne_binary().
set_queue('private') ->
    persistent_term:put('ecallmgr_call_control_amqp_queue', 'undefined'),
    'undefined';
set_queue('shared') ->
    Queue = list_to_binary([<<"callctl-">>, kz_binary:rand_uuid()]),
    persistent_term:put('ecallmgr_call_control_amqp_queue', Queue),
    Queue;
set_queue(_) ->
    persistent_term:put('ecallmgr_call_control_amqp_queue', 'undefined'),
    'undefined'.

-spec set_control_q_strategy(atom()) -> 'ok'.
set_control_q_strategy(Strategy) ->
    persistent_term:put('ecallmgr_call_control_control_q_strategy', Strategy).

-spec control_q_strategy() -> atom().
control_q_strategy() ->
    persistent_term:get('ecallmgr_call_control_control_q_strategy', 'direct').

-spec set_direct_control_q_strategy(atom()) -> 'ok'.
set_direct_control_q_strategy(Strategy) ->
    persistent_term:put('ecallmgr_call_control_direct_control_q_strategy', Strategy).

-spec direct_control_q_strategy() -> atom().
direct_control_q_strategy() ->
    persistent_term:get('ecallmgr_call_control_direct_control_q_strategy', 'sequential').

-spec start_call_control(map()) -> kz_types:sup_startchild_ret().
start_call_control(#{call_id := CallId} = Context) ->
    lager:debug("starting call control for ~s", [CallId]),
    start_proc(Context).

-spec start_proc(map()) -> kz_types:sup_startchild_ret().
start_proc(Map) ->
    ecallmgr_call_control_sup:start_call_control(control_q(Map)).

control_q(#{control_q := _Queue}= Map) ->
    Map;
control_q(#{control_q_callback := Fun}= Map) ->
    Fun(Map);
control_q(Map) ->
    control_q(Map, control_q_strategy()).

control_q(Map, 'direct') ->
    {Channel, Queue} = direct_control_ref(direct_control_q_strategy()),
    Map#{control_q => Queue
        ,channel => Channel
        }.

-spec remove_listener(pid(), state()) -> state().
remove_listener(Pid, State) ->
    #{listeners := Listeners, channels := Channels, refs := Refs} = State,
    case maps:get(Pid, Listeners, 'undefined') of
        'undefined' -> State;
        #{channel := Channel, monitor := ListenerMonitor} ->
            erlang:demonitor(ListenerMonitor),
            #{monitor := ChannelMonitor} = maps:get(Channel, Channels),
            erlang:demonitor(ChannelMonitor),
            NewRefs = maps:without([ListenerMonitor, ChannelMonitor], Refs),
            NewListeners = maps:without([Pid], Listeners),
            NewChannels = maps:without([Channel], Channels),
            State#{refs => NewRefs, listeners => NewListeners, channels => NewChannels}
    end.

-spec add_listener(pid(), pid(), kz_term:ne_binary(), boolean(), state()) -> state().
add_listener(Pid, Channel, Queue, Active, State0) ->
    State = remove_listener(Pid, State0),
    #{listeners := Listeners, channels := Channels, refs := Refs} = State,

    ListenerRef = erlang:monitor('process', Pid),
    ChannelRef = erlang:monitor('process', Channel),

    NewListeners = maps:put(Pid, #{channel => Channel, queue => Queue, monitor => ListenerRef}, maps:without([Pid], Listeners)),
    NewChannels = maps:put(Channel, #{listener => Pid, queue => Queue, monitor => ChannelRef}, maps:without([Channel], Channels)),

    NewRefs0 = maps:put(ListenerRef, #{listener => Pid}, Refs),
    NewRefs = maps:put(ChannelRef, #{channel => Channel}, NewRefs0),

    case Active of
        'true' -> set_control_refs(NewChannels);
        'false' -> set_control_refs(maps:without([Channel], NewChannels))
    end,

    State#{listeners => NewListeners, channels => NewChannels, refs => NewRefs}.

-spec init_queues(state()) -> state().
init_queues(#{workers := Workers, queue := Queue} = State) ->
    start_listeners(Workers, Queue),
    State.

-spec start_listeners(pos_integer(), kz_term:ne_binary()) -> 'ok'.
start_listeners(Workers, Queue) ->
    start_listeners(Workers, Queue, self()).

-spec start_listeners(pos_integer(), kz_term:ne_binary(), pid()) -> 'ok'.
start_listeners(Workers, Queue, Self) ->
    lists:foreach(fun(_) -> start_listener(Self, Queue) end, lists:seq(1, Workers)).

-spec start_listener(pid(), kz_term:ne_binary()) -> kz_types:startlink_ret().
start_listener(Self, Queue) ->
    ecallmgr_call_control_listener_sup:start_listener(Self, Queue).

counter() ->
    case persistent_term:get('ecallmgr_call_control_manager_counter', 'undefined') of
        'undefined' ->
            Ref = counters:new(1, ['write_concurrency']),
            persistent_term:put('ecallmgr_call_control_manager_counter', Ref),
            Ref;
        Ref ->
            Ref
    end.

next() ->
    counters:add(counter(), 1, 1),
    counters:get(counter(), 1).

-spec set_control_refs(map() | 'undefined') -> 'ok'.
set_control_refs('undefined') ->
    persistent_term:put('call_control_listener_refs', []);
set_control_refs(Channels) ->
    persistent_term:put('call_control_listener_refs', maps:fold(fun build_control_ref/3, [], Channels)).

build_control_ref(Channel, #{queue := Queue}, Acc)->
    [{Channel, Queue} | Acc].


control_refs() ->
    persistent_term:get('call_control_listener_refs').

%% without going thru gen_server:call
direct_control_ref('random') ->
    ControlRefs = control_refs(),
    Index = rand:uniform(length(ControlRefs)),
    lists:nth(Index, ControlRefs);
direct_control_ref('sequential') ->
    ControlRefs = control_refs(),
    Index = next() rem length(ControlRefs),
    lists:nth(Index + 1, ControlRefs).

handle_canary('false', Channel, State) ->
    gen_server:cast(self(), 'init_queues'),
    handle_canary(Channel, State);
handle_canary('true', Channel, #{channels := Channels} = State) ->
    set_control_refs(Channels),
    handle_canary(Channel, State).

handle_canary(Channel, #{refs := Refs} = State) ->
    ChannelRef = erlang:monitor('process', Channel),
    NewRefs = maps:put(ChannelRef, #{canary => Channel}, Refs),
    State#{canary => Channel, refs => NewRefs}.

handle_down(Pid, Ref, Reason, #{refs := Refs} = State) ->
    case maps:get(Ref, Refs, 'undefined') of
        'undefined' ->
            lager:warning("received down (~p/~p/~p) => unmanaged", [Pid, Ref, Reason]),
            State;
        Managed ->
            handle_down(Pid, Ref, Reason, Managed, State)
    end.

handle_down(Pid, Ref, Reason, #{canary := Pid}, #{refs := Refs, canary := Pid} = State) ->
    lager:warning("received down (~p/~p/~p) for canary channel, we're closing until we get it back", [Pid, Ref, Reason]),
    set_control_refs('undefined'),
    NewRefs = maps:without([Ref], Refs),
    State#{refs => NewRefs};
handle_down(Pid, Ref, Reason, #{listener := Pid}, State) ->
    lager:warning("received down (~p/~p/~p) for listener, this is bad.", [Pid, Ref, Reason]),
    NewState = #{channels := Channels} = remove_listener(Pid, State),
    set_control_refs(Channels),
    NewState;
handle_down(Pid, Ref, Reason, #{channel := Pid}, #{channels := Channels} = State) ->
    lager:warning("received down (~p/~p/~p) for channel, this is bad.", [Pid, Ref, Reason]),
    #{listener := ListenerPid} = maps:get(Pid, Channels),
    NewState = #{channels := NewChannels} = remove_listener(ListenerPid, State),
    set_control_refs(NewChannels),
    NewState.
