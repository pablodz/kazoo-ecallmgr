%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_call_control_listener).

-behaviour(gen_listener).

-export([start_link/2]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-include("ecallmgr.hrl").

-define(RESPONDERS, []).

-define(BINDINGS, [{'dialplan', []}
                  ,{'self', []}
                  ]).

-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).
-define(SHARED_QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(SHARED_CONSUME_OPTIONS, [{'exclusive', 'false'}]).

-define(QOS, 50).

-type state() :: #{manager := pid()
                  ,active => boolean()
                  ,queue => kz_term:api_ne_binary()
                  }.

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec start_link(pid(), kz_term:api_ne_binary()) -> kz_types:startlink_ret().
start_link(Manager, Queue) ->
    gen_listener:start_link(?MODULE
                           ,[{'responders', ?RESPONDERS}
                            ,{'bindings', ?BINDINGS}
                            ,{'basic_qos', ?QOS}
                            | queue_settings(Queue)
                            ]
                           ,[Manager]
                           ).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server
%%
%% @end
%%------------------------------------------------------------------------------
-spec init([pid()]) -> {'ok', state()}.
init([Pid]) ->
    process_flag('trap_exit', 'true'),
    lager:info("starting new call control listener"),
    {'ok', #{manager => Pid}}.

-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> {'noreply', state()}.
handle_cast({'gen_listener',{'is_consuming', Active}}
           ,#{manager := Pid
             ,queue := Queue
             }=State
           ) ->
    lager:info("call control listener is ~s, notifying manager", [is_consuming_description(Active)]),
    gen_server:cast(Pid, {'call_control_listener_is_ready', self(), kz_amqp_channel:consumer_channel(), Queue, Active}),
    {'noreply', State#{active => Active}};
handle_cast({'gen_listener',{'created_queue', QueueName}}, State) ->
    {'noreply', State#{queue => QueueName}};
handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State, 'hibernate'}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("call control listener termination: ~p", [ _Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed
%%
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

is_consuming_description('true') -> <<"consuming">>;
is_consuming_description('false') -> <<"not consuming">>.

queue_settings('undefined') ->
    [{'queue_name', list_to_binary([<<"callctl-">>, kz_binary:rand_uuid()])}
    ,{'queue_options', ?QUEUE_OPTIONS}
    ,{'consume_options', ?CONSUME_OPTIONS}
    ];
queue_settings(Queue) ->
    [{'queue_name', Queue}
    ,{'queue_options', ?SHARED_QUEUE_OPTIONS}
    ,{'consume_options', ?SHARED_CONSUME_OPTIONS}
    ].
