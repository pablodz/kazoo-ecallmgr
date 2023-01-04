%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2023, 2600Hz
%%% @doc
%%% @author Karl Anderson
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_resource).
-behaviour(gen_listener).

-export([start_link/1, start_link/2]).
-export([handle_originate_req/2]).
-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-record(state, {node :: atom()
               ,options :: kz_term:proplist()
               ,self :: kz_term:api_ne_binary()
               ,node_queue :: kz_term:ne_binary()
               ,shared_queue :: kz_term:ne_binary()
               }).
-type state() :: #state{}.

-define(SHARED_BINDINGS, [{'resource', [{'restrict_to', ['originate']}]}]).
-define(NODE_BINDINGS(N), [{'resource', [{'restrict_to', ['originate']}, {'node', N}, 'federate']}]).
-define(SELF_BINDINGS, [{'self', []}]).

-define(RESPONDERS, [{{?MODULE, 'handle_originate_req'}, [{<<"resource">>, <<"originate_req">>}]}]).


-define(SHARED_QUEUE_NAME, <<"ecallmgr_fs_resource">>).
-define(SHARED_QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(SHARED_QUEUE_CONSUME_OPTIONS, [{'exclusive', 'false'}]).
-define(SHARED_QUEUE_PARAMS, [{'queue_options', ?SHARED_QUEUE_OPTIONS}
                             ,{'consume_options', ?SHARED_QUEUE_CONSUME_OPTIONS}
                             ]).

-define(NODE_QUEUE_NAME(N), <<"ecallmgr_fs_resource_", (kz_term:to_binary(N))/binary>>).
-define(NODE_QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(NODE_QUEUE_CONSUME_OPTIONS, [{'exclusive', 'false'}]).
-define(NODE_QUEUE_PARAMS, [{'queue_options', ?NODE_QUEUE_OPTIONS}
                           ,{'consume_options', ?NODE_QUEUE_CONSUME_OPTIONS}
                           ]).

-define(SELF_QUEUE_NAME, <<>>).
-define(SELF_QUEUE_OPTIONS, []).
-define(SELF_QUEUE_CONSUME_OPTIONS, []).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------

-spec start_link(atom()) -> kz_types:startlink_ret().
start_link(Node) -> start_link(Node, []).

-spec start_link(atom(), kz_term:proplist()) -> kz_types:startlink_ret().
start_link(Node, Options) ->
    gen_listener:start_link(?MODULE
                           ,[{'bindings', ?SELF_BINDINGS}
                            ,{'responders', ?RESPONDERS}
                            ,{'queue_name', ?SELF_QUEUE_NAME}
                            ,{'queue_options', ?SELF_QUEUE_OPTIONS}
                            ,{'consume_options', ?SELF_QUEUE_CONSUME_OPTIONS}
                            ],
                            [Node, Options]
                           ).

-spec handle_originate_req(kz_json:object(), kz_term:proplist()) -> kz_types:sup_startchild_ret().
handle_originate_req(JObj, Props) ->
    _ = kz_log:put_callid(JObj),
    Arg = #{node => props:get_value('node', Props)
           ,queue => props:get_value('self', Props)
           ,payload => JObj
           ,channel => kz_amqp_channel:consumer_channel()
           },
    ecallmgr_originate_sup:start_originate_proc(Arg).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([atom() | kz_term:proplist()]) -> {'ok', state()}.
init([Node, Options]) ->
    process_flag('trap_exit', 'true'),
    kz_log:put_callid(Node),
    lager:info("starting new fs resource listener for ~s", [Node]),
    {'ok', #state{node = Node
                 ,options = Options
                 ,node_queue = ?NODE_QUEUE_NAME(Node)
                 ,shared_queue = ?SHARED_QUEUE_NAME
                 }
    }.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'gen_listener', {'created_queue', Q}}, #state{shared_queue=Q} = State) ->
    lager:debug("started shared queue ~s", [Q]),
    {'noreply', State};
handle_cast({'gen_listener', {'created_queue', Q}}, #state{node_queue=Q} = State) ->
    lager:debug("started node shared queue ~s", [Q]),
    gen_server:cast(self(), {'add_queue', ?SHARED_QUEUE_NAME, ?SHARED_QUEUE_PARAMS, ?SHARED_BINDINGS}),
    {'noreply', State};
handle_cast({'gen_listener', {'created_queue', Q}}, #state{node=Node} = State) ->
    lager:debug("started self queue ~s", [Q]),
    gen_server:cast(self(), {'add_queue', ?NODE_QUEUE_NAME(Node), ?NODE_QUEUE_PARAMS, ?NODE_BINDINGS(Node)}),
    {'noreply', State#state{self = Q}};
handle_cast(_Msg, State) ->
    {'noreply', State}.


%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'update_options', NewOptions}, State) ->
    {'noreply', State#state{options=NewOptions}, 'hibernate'};
handle_info({'EXIT', _, 'noconnection'}, State) ->
    {'stop', {'shutdown', 'noconnection'}, State};
handle_info({'EXIT', _, Reason}, State) ->
    {'stop', Reason, State};
handle_info(_Info, State) ->
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> gen_listener:handle_event_return().
handle_event(_JObj, #state{node=Node, self=Self}) ->
    {'reply', [{'node', Node}
              ,{'self', Self}
              ]
    }.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, #state{node=Node}) ->
    lager:info("resource listener for ~s terminating: ~p", [Node, _Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
