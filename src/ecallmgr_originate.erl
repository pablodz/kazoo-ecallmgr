%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2025, 2600Hz
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
-module(ecallmgr_originate).
-behaviour(gen_server).

-export([start_link/1]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).

-record(state, {node :: atom()
               ,server_id :: kz_term:api_binary()
               ,controller_q :: kz_term:api_binary()
               ,originate_req = kz_json:new() :: kz_json:object()
               ,action :: kz_term:api_binary()
               ,app :: kz_term:api_binary()
               ,dialstrings :: kz_term:api_binary()
               ,queue :: kz_term:api_binary()
               ,tref :: kz_term:api_reference()
               ,originate_uuid :: kz_term:ne_binary()
               ,control_pid :: kz_term:api_pid()
               ,uuid :: kz_term:api_binary()
               ,start_control_process :: boolean()
               ,originate_pid_ref :: kz_term:api_pid_ref()
               }).
-type state() :: #state{}.

-define(ORIGINATE_PARK, <<"&park()">>).
-define(REPLY_TIMEOUT, 5 * ?MILLISECONDS_IN_SECOND).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-type originate_args() :: #{node := node() %% FS node from ecallmgr_fs_resource handler
                           ,queue := kz_term:ne_binary() %% gen_listener targeted queue for ecallmgr_fs_resource
                           ,payload := kapi_resource:originate_req()
                           ,channel := pid() %% AMQP channel pid
                           }.
-spec start_link(originate_args()) -> kz_types:startlink_ret().
start_link(Map) ->
    gen_server:start_link(?SERVER, [Map], []).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([originate_args()]) ->
          {'ok', state()} |
          {'stop', 'normal'}.
init([#{payload := JObj
       ,node := Node
       ,queue := Queue
       ,channel := Channel
       }]) ->
    _ = kz_log:put_callid(JObj),
    kz_amqp_channel:consumer_channel(Channel),
    ServerId = kz_api:server_id(JObj),
    OriginateUUID = kz_json:get_ne_binary_value(<<"Originate-UUID">>, JObj, kz_binary:rand_hex(16)),
    case kapi_resource:originate_req_v(JObj) of
        'false' ->
            Error = <<"originate failed to execute as JObj did not validate">>,
            publish_error(Error, 'undefined', JObj, ServerId),
            {'stop', 'normal'};
        'true' ->
            ControllerQ = kz_api:queue_id(JObj),
            bind_to_originate_events(Node, OriginateUUID),
            gen_server:cast(self(), 'originate_action'),
            {'ok', #state{node=fs_node_to_use(JObj, Node)
                         ,originate_req=JObj
                         ,server_id=ServerId
                         ,controller_q = ControllerQ
                         ,queue = Queue
                         ,originate_uuid = OriginateUUID
                         ,start_control_process = should_start_control_process(JObj)
                         }}
    end.

default_action_start_control_process(<<"transfer">>) -> false;
default_action_start_control_process(_Action) -> true.

default_start_control_process(JObj) ->
    default_action_start_control_process(application_name(JObj)).

should_start_control_process(JObj) ->
    Default = default_start_control_process(JObj),
    kz_json:is_true(<<"Start-Control-Process">>, JObj, Default).

fs_node_to_use(JObj, Node) ->
    case kz_json:get_binary_value(<<"Existing-Call-ID">>, JObj) of
        'undefined' ->
            lager:info("using configured media node ~s", [Node]),
            Node;
        ExistingCallId ->
            case ecallmgr_fs_channel:node(ExistingCallId) of
                {'ok', FSNode} ->
                    lager:info("existing call_id ~s on ~s, using that", [ExistingCallId, FSNode]),
                    FSNode;
                {'error', 'not_found'} ->
                    lager:info("existing call_id ~s not found, using configured node ~s"
                              ,[ExistingCallId, Node]
                              ),
                    Node
            end
    end.

-spec bind_to_originate_events(atom(), kz_term:ne_binary()) -> 'ok'.
bind_to_originate_events(Node, OriginateUUID) ->
    gproc:reg({'p', 'l', ?FS_EVENT_ORIGINATE_MSG_UUID(Node, OriginateUUID)}),
    'ok'.

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
handle_cast('originate_action', #state{originate_req=JObj
                                      ,node=Node
                                      }=State) ->
    gen_server:cast(self(), 'build_originate'),
    Action = get_originate_action(JObj, Node),
    lager:debug("originate action: ~s", [Action]),
    {'noreply', State#state{app = application_name(JObj)
                           ,action = Action
                           }
    ,'hibernate'
    };

handle_cast('build_originate', #state{originate_req=JObj
                                     ,action=Action
                                     }=State) ->
    case kz_json:is_true(<<"Originate-Immediate">>, JObj, 'true') of
        'true'  -> gen_server:cast(self(), 'originate_execute');
        'false' -> gen_server:cast(self(), 'originate_ready')
    end,
    {'noreply', State#state{dialstrings=build_originate(Action, JObj)}};

handle_cast('originate_ready', #state{dialstrings='undefined'
                                     ,server_id=ServerId
                                     ,originate_uuid=UUID
                                     ,originate_req=JObj
                                     }=State) ->
    _ = publish_error(<<"no dialstring">>, UUID, JObj, ServerId),
    {'stop', 'normal', State};

handle_cast('originate_execute', #state{dialstrings='undefined'
                                       ,server_id=ServerId
                                       ,originate_uuid=UUID
                                       ,originate_req=JObj
                                       }=State) ->
    _ = publish_error(<<"no dialstring">>, UUID, JObj, ServerId),
    {'stop', 'normal', State};

handle_cast('originate_ready', #state{server_id='undefined'}=State) ->
    lager:debug("originate command is ready, but no server-id, sending execute"),
    gen_server:cast(self(), 'originate_execute'),
    {'noreply', State};

handle_cast('originate_ready', #state{queue=Queue
                                     ,originate_uuid=UUID
                                     ,originate_req=JObj
                                     ,server_id=ServerId
                                     }=State) ->

    publish_originate_ready(UUID, JObj, kapi:encode_pid(Queue, self()), ServerId),
    lager:debug("originate command is ready, waiting for originate_execute"),
    {'noreply', State#state{tref=start_abandon_timer()}};

handle_cast('originate_execute', #state{tref=TRef}=State) when is_reference(TRef) ->
    _ = erlang:cancel_timer(TRef),
    handle_cast('originate_execute', State#state{tref='undefined'});

handle_cast('originate_execute', #state{dialstrings=Dialstrings
                                       ,node=Node
                                       ,originate_uuid=OriginateUUID
                                       }=State) ->
    {'noreply', State#state{originate_pid_ref = originate_execute(Node, OriginateUUID, Dialstrings)}};

handle_cast('originate_cancel', #state{node=Node
                                      ,originate_uuid=OriginateUUID
                                      }=State) ->
    _ = freeswitch:api(Node, 'kz_originate_cancel', OriginateUUID),
    {'noreply', State};

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', State, 'hibernate'}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'kapi', {{_Ex, _RK, {_Basic, _Deliver}}
                     ,{'dialplan', 'originate_execute'}
                     ,_Payload
                     }}
           ,State
           ) ->
    lager:info("received originate execute"),
    gen_server:cast(self(), 'originate_execute'),
    {'noreply', State};

handle_info({'kapi', {{_Ex, _RK, {_Basic, _Deliver}}
                     ,{'dialplan', 'originate_cancel'}
                     ,_Payload
                     }}
           ,State
           ) ->
    lager:info("received originate cancel"),
    gen_server:cast(self(), 'originate_cancel'),
    {'noreply', State};

handle_info('abandon_originate', #state{tref='undefined'}=State) ->
    %% Cancelling a timer does not guarantee that the message has not
    %% already been delivered to the message queue.
    {'noreply', State};

handle_info('abandon_originate', #state{originate_req=JObj
                                       ,originate_uuid=UUID
                                       ,server_id=ServerId
                                       }=State) ->
    Error = <<"Failed to receive valid originate_execute in time">>,
    publish_error(Error, UUID, JObj, ServerId),
    {'stop', 'normal', State};

handle_info({'originate_result', {'ok', UUID}}, #state{originate_uuid=OriginateUUID
                                                      ,controller_q='undefined'
                                                      }=State) ->
    lager:debug("originate completed with no controller queue for: ~s / ~s", [OriginateUUID, UUID]),
    {'stop', 'normal', State};
handle_info({'originate_result', {'ok', UUID}}, #state{originate_req=JObj
                                                      ,originate_uuid=OriginateUUID
                                                      ,controller_q=ServerId
                                                      ,start_control_process='true'
                                                      }=State) ->
    lager:debug("originate completed for: ~s / ~s", [OriginateUUID, UUID]),
    {'ok', #state{control_pid=CtrlPid}=NewState} = start_control_process(State#state{uuid=UUID}),
    CtrlQ = ecallmgr_call_control:queue_name(CtrlPid),
    publish_originate_resp(ServerId, JObj, OriginateUUID, UUID, CtrlQ),
    {'stop', 'normal', NewState};

handle_info({'originate_result', {'ok', UUID}}, #state{originate_req=JObj
                                                      ,originate_uuid=OriginateUUID
                                                      ,controller_q=ServerId
                                                      ,start_control_process='false'
                                                      }=State) ->
    lager:debug("originate completed without starting control queue for: ~s", [UUID]),
    publish_originate_resp(ServerId, JObj, OriginateUUID, UUID),
    {'stop', 'normal', State};

handle_info({'originate_result', {'error', Error}}, #state{originate_req=JObj
                                                          ,originate_uuid=OriginateUUID
                                                          ,controller_q=ServerId
                                                          }=State) ->
    publish_error(Error, OriginateUUID, JObj, ServerId),
    {'stop', 'normal', State};

handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State, 'hibernate'}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) -> 'ok'.

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

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec cache_fax_file(kz_term:ne_binary(), node()) -> {'ok' | 'error', kz_term:ne_binary()}.
cache_fax_file(File, Node) ->
    Self = self(),
    Fun = fun(Res, Reply) ->
                  lager:debug("cache fax file result : ~p", [{Res, Reply}]),
                  Self ! {'cache_fax_file', {Res, Reply}}
          end,
    {'ok', JobId} = freeswitch:bgapi(Node, 'http_get', <<"{prefetch=true}", File/binary>>, Fun),
    lager:debug("waiting for cache fax file result ~s", [JobId]),
    receive
        {'cache_fax_file', Reply} -> Reply
    end.

-spec application_name(kz_json:object()) -> kz_term:ne_binary().
application_name(JObj) ->
    kz_json:get_ne_binary_value(<<"Application-Name">>, JObj).

-spec get_originate_action(kz_json:object(), node()) -> kz_term:ne_binary().
get_originate_action(JObj, Node) ->
    get_originate_action(application_name(JObj), JObj, Node).

-spec get_originate_action(kz_term:ne_binary(), kz_json:object(), node()) -> kz_term:ne_binary().
get_originate_action(<<"fax">>, JObj, Node) ->
    lager:debug("got originate with action fax"),
    Data = kz_json:get_value(<<"Application-Data">>, JObj),
    {'ok', File} = cache_fax_file(Data, Node),
    <<"&txfax(", File/binary, ")">>;
get_originate_action(<<"transfer">>, JObj, _Node) ->
    get_transfer_action(JObj, kz_json:get_value([<<"Application-Data">>, <<"Route">>], JObj));
get_originate_action(<<"bridge">>, JObj, _Node) ->
    lager:debug("got originate with action bridge"),
    CallId = kz_json:get_binary_value(<<"Existing-Call-ID">>, JObj),
    intercept_unbridged_only(CallId, JObj);
get_originate_action(<<"eavesdrop">>, JObj, _Node) ->
    lager:debug("got originate with action eavesdrop"),
    get_eavesdrop_action(JObj);
get_originate_action(<<"extension">>, JObj, _) ->
    lager:debug("got originate with action extension"),
    get_extension_action(JObj);
get_originate_action(<<"park">>, _, _) ->
    lager:debug("got originate with action park"),
    ?ORIGINATE_PARK;
get_originate_action(_ , _, _) ->
    lager:debug("setting default originate action to park"),
    ?ORIGINATE_PARK.

-spec get_transfer_action(kz_json:object(), kz_term:api_binary()) -> kz_term:ne_binary().
get_transfer_action(_JObj, 'undefined') -> <<"error">>;
get_transfer_action(JObj, Route) ->
    Context = ?DEFAULT_FREESWITCH_CONTEXT,
    UnsetVars = get_unset_vars(JObj),
    TransferAction = UnsetVars ++ ["^transfer:", Route, " XML ", Context],
    list_to_binary(["'m:^:", TransferAction, "' inline"]).

-spec get_extension_action(kz_json:object()) -> kz_term:ne_binary().
get_extension_action(JObj) ->
    Data = kz_json:get_json_value(<<"Application-Data">>, JObj),
    Extension = kz_json:get_ne_binary_value(<<"Extension">>, Data, <<"error">>),
    Dialplan = kz_json:get_ne_binary_value(<<"Dialplan">>, Data, ?DEFAULT_FS_DIALPLAN),
    Context = kz_json:get_ne_binary_value(<<"Context">>, Data, ?DEFAULT_FREESWITCH_CONTEXT),
    list_to_binary([Extension, " ", Dialplan, " ", Context]).

-spec intercept_unbridged_only(kz_term:ne_binary() | 'undefined', kz_json:object()) -> kz_term:ne_binary().
intercept_unbridged_only('undefined', JObj) ->
    get_bridge_action(JObj);
intercept_unbridged_only(ExistingCallId, JObj) ->
    case kz_json:is_true(<<"Intercept-Unbridged-Only">>, JObj, 'true') of
        'true' ->
            <<" 'set:intercept_unbridged_only=true,intercept:", ExistingCallId/binary, "' inline ">>;
        'false' ->
            <<" 'set:intercept_unbridged_only=false,intercept:", ExistingCallId/binary, "' inline ">>
    end.

-spec get_bridge_action(kz_json:object()) -> kz_term:ne_binary().
get_bridge_action(JObj) ->
    Data = kz_json:get_value(<<"Application-Data">>, JObj),
    case ecallmgr_util:build_channel(Data) of
        {'error', _} -> <<"error">>;
        {'ok', Channel} ->
            UnsetVars = get_unset_vars(JObj),
            BridgeAction = UnsetVars ++ ["^bridge:", Channel],
            list_to_binary(["'m:^:", BridgeAction, "' inline"])
    end.

-spec get_eavesdrop_action(kz_json:object()) -> kz_term:ne_binary().
get_eavesdrop_action(JObj) ->
    {CallId, Group} = case kz_json:get_value(<<"Eavesdrop-Group-ID">>, JObj) of
                          'undefined' -> {kz_json:get_binary_value(<<"Eavesdrop-Call-ID">>, JObj), <<>>};
                          ID -> {<<"all">>, <<"eavesdrop_require_group=", ID/binary, ",">>}
                      end,
    case kz_json:get_value(<<"Eavesdrop-Mode">>, JObj) of
        <<"whisper">> -> <<Group/binary, "queue_dtmf:w2@500,eavesdrop:", CallId/binary, " inline">>;
        <<"full">> -> <<Group/binary, "queue_dtmf:w3@500,eavesdrop:", CallId/binary, " inline">>;
        <<"listen">> -> <<Group/binary, "eavesdrop:", CallId/binary, " inline">>;
        'undefined' -> <<Group/binary, "eavesdrop:", CallId/binary, " inline">>
    end.

-spec build_originate(kz_term:ne_binary(), kz_json:object()) -> kz_term:api_binary().
build_originate(Action, JObj) ->
    case kz_json:get_value(<<"Endpoints">>, JObj, []) of
        [] ->
            lager:warning("no endpoints defined in originate request"),
            'undefined';
        Endpoints ->
            build_originate(Action, Endpoints, JObj)
    end.

-spec build_originate(kz_term:ne_binary(), kz_json:objects(), kz_json:object()) ->
          kz_term:ne_binary().
build_originate(Action, Endpoints, JObj) ->
    lager:debug("building originate command arguments"),
    DialSeparator = ecallmgr_util:get_dial_separator(JObj, Endpoints),

    DialStrings = ecallmgr_util:build_bridge_string(Endpoints, DialSeparator),

    ChannelVars = get_channel_vars(JObj),

    list_to_binary([ChannelVars, DialStrings, " ", Action]).

-spec get_channel_vars(kz_json:object()) -> iolist().
get_channel_vars(JObj) ->
    InteractionId = kz_json:get_value([<<"Custom-Channel-Vars">>, <<?CALL_INTERACTION_ID>>], JObj, ?CALL_INTERACTION_DEFAULT),
    CCVs = [{<<"Ecallmgr-Node">>, kz_term:to_binary(node())}
           ,{<<?CALL_INTERACTION_ID>>, InteractionId}
           ,{<<"Call-Flag-NO-Flip">>, 'true'}
           ],
    J = kz_json:from_list_recursive([{<<"Custom-Channel-Vars">>, add_ccvs(JObj, CCVs)}]),
    ecallmgr_fs_xml:get_channel_vars(kz_json:merge(JObj, J)).

-spec add_ccvs(kz_json:object(), kz_term:proplist()) -> kz_term:proplist().
add_ccvs(JObj, Props) ->
    Routines = [fun maybe_add_loopback/2
               ],
    lists:foldl(fun(Fun, Acc) -> Fun(JObj, Acc) end, Props, Routines).

-spec maybe_add_loopback(kz_json:object(), kz_term:proplist()) -> kz_term:proplist().
maybe_add_loopback(JObj, Props) ->
    case kz_json:get_binary_boolean(<<"Simplify-Loopback">>, JObj) of
        'undefined' -> Props;
        SimpliFly -> add_loopback(kz_term:is_true(SimpliFly)) ++ Props
    end.

-spec add_loopback(boolean()) -> kz_term:proplist().
add_loopback('true') ->
    [{<<"Simplify-Loopback">>, 'true'}
    ,{<<"Loopback-Bowout">>, 'true'}
    ];
add_loopback('false') ->
    [{<<"Simplify-Loopback">>, 'false'}
    ,{<<"Loopback-Bowout">>, 'false'}
    ].

-spec originate_execute(atom(), kz_term:ne_binary(), kz_term:ne_binary()) ->
          kz_term:pid_ref().
originate_execute(Node, UUID, Dialstrings) ->
    lager:debug("executing originate on ~s / ~s ~s", [Node, UUID, Dialstrings]),
    kz_process:spawn_monitor(fun originate_execute_async/4, [self(), Node, UUID, Dialstrings]).

-spec originate_execute_async(pid(), atom(), kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'originate_result', freeswitch:fs_api_return()}.
originate_execute_async(Pid, Node, UUID, Dialstrings) ->
    Arg = list_to_binary([UUID, " ", Dialstrings]),
    Res = freeswitch:async_api(Node, 'kz_originate', Arg),
    Pid ! {'originate_result', Res}.

-spec get_unset_vars(kz_json:object()) -> iolist().
get_unset_vars(JObj) ->
    %% Refactor (Karl wishes he had unit tests here for you to use)
    ExportProps = [{K, <<>>} || K <- kz_json:get_value(<<"Export-Custom-Channel-Vars">>, JObj, [])],
    Export = [K || KV <- lists:foldr(fun ecallmgr_fs_xml:kazoo_var_to_fs_var/2
                                    ,[]
                                    ,[{<<"Custom-Channel-Vars">>, kz_json:from_list(ExportProps)}]
                                    ),
                   ([K, _] = string:tokens(binary_to_list(KV), "=")) =/= 'undefined'
             ],

    %% Maintain CAVs on b-legs
    WithoutCAVs = kz_json:delete_key(<<"Custom-Application-Vars">>, JObj),
    VarsToUnset = lists:foldr(fun ecallmgr_fs_xml:kazoo_var_to_fs_var/2
                             ,[]
                             ,kz_json:to_proplist(WithoutCAVs)
                             ),

    case ["unset:" ++ K
          || KV <- VarsToUnset
                 ,not lists:member(begin [K, _] = string:tokens(binary_to_list(KV), "="), K end, Export)]
    of
        [] -> "";
        Unset ->
            [string:join(Unset, "^")
            ,maybe_fix_ignore_early_media(Export)
            ,maybe_fix_group_confirm(Export)
            ,maybe_fix_fs_auto_answer_bug(Export)
            ,maybe_fix_caller_id(Export, JObj)
            ]
    end.

-spec maybe_fix_ignore_early_media(kz_term:strings()) -> string().
maybe_fix_ignore_early_media(Export) ->
    case lists:member("ignore_early_media", Export) of
        'true' -> "";
        'false' -> "^unset:ignore_early_media"
    end.

-spec maybe_fix_group_confirm(kz_term:strings()) -> string().
maybe_fix_group_confirm(Export) ->
    case lists:member("group_confirm_key", Export) of
        'true' -> "";
        'false' -> "^unset:group_confirm_key^unset:group_confirm_cancel_timeout^unset:group_confirm_file"
    end.

-spec maybe_fix_fs_auto_answer_bug(kz_term:strings()) -> string().
maybe_fix_fs_auto_answer_bug(Export) ->
    case lists:member("sip_auto_answer", Export) of
        'true' -> "";
        'false' ->
            "^unset:sip_h_Call-Info^unset:sip_h_Alert-Info^unset:alert_info^unset:sip_invite_params^set:sip_auto_answer=false"
    end.

-spec maybe_fix_caller_id(kz_term:strings(), kz_json:object()) -> string().
maybe_fix_caller_id(Export, JObj) ->
    Fix = [
           {lists:member("origination_callee_id_name", Export)
           ,kz_json:get_value(<<"Outbound-Callee-ID-Name">>, JObj)
           ,"origination_caller_id_name"
           }
          ,{lists:member("origination_callee_id_number", Export)
           ,kz_json:get_value(<<"Outbound-Callee-ID-Number">>, JObj)
           ,"origination_caller_id_number"
           }
          ],
    string:join(["^set:" ++ Key ++ "=" ++ erlang:binary_to_list(ecallmgr_util:fs_arg_encode(Value))
                 || {IsTrue, Value, Key} <- Fix,
                    IsTrue
                ]
               ,":"
               ).

-spec publish_error(kz_term:ne_binary(), kz_term:api_binary(), kz_json:object(), kz_term:api_binary()) -> 'ok'.
publish_error(_, _, _, 'undefined') -> 'ok';
publish_error(Error, UUID, Request, ServerId) ->
    lager:debug("originate error: ~s", [Error]),
    E = [{<<"Msg-ID">>, kz_api:msg_id(Request)}
        ,{<<"Call-ID">>, UUID}
        ,{<<"Request">>, Request}
        ,{<<"Error-Message">>, cleanup_error(Error)}
        | kz_api:default_headers(<<"error">>, <<"originate_resp">>, ?APP_NAME, ?APP_VERSION)
        ],
    kz_api:publish_error(ServerId, props:filter_undefined(E)).

-spec cleanup_error(kz_term:ne_binary()) -> kz_term:ne_binary().
cleanup_error(<<"-ERR ", E/binary>>) -> E;
cleanup_error(E) -> E.

-spec publish_originate_ready(kz_term:ne_binary(), kz_json:object(), kz_term:ne_binary(), kz_term:api_binary()) -> 'ok'.
publish_originate_ready(UUID, Request, Q, ServerId) ->
    lager:debug("sending originate_ready to ~s", [ServerId]),
    Props = [{<<"Msg-ID">>, kz_api:msg_id(Request, UUID)}
            ,{<<"Originate-UUID">>, UUID}
            ,{<<"Originate-Queue">>, Q}
            | kz_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
            ],
    kapi_dialplan:publish_originate_ready(ServerId, Props).

-spec publish_originate_resp(kz_term:api_binary(), kz_json:object(), kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
publish_originate_resp('undefined', _JObj, _OriginateUUID, _UUID) ->
    lager:debug("not sending originate_resp server_id=undefined, originate_uuid=~s, uuid=~s", [_OriginateUUID, _UUID]);
publish_originate_resp(ServerId, JObj, OriginateUUID, UUID) ->
    lager:debug("sending originate_resp to server_id=~s, originate_uuid=~s, uuid=~s", [ServerId, OriginateUUID, UUID]),
    Resp = kz_json:set_values([{<<"Event-Category">>, <<"resource">>}
                              ,{<<"Application-Response">>, <<"SUCCESS">>}
                              ,{<<"Event-Name">>, <<"originate_resp">>}
                              ,{<<"Call-ID">>, UUID}
                              ,{<<"Originate-UUID">>, OriginateUUID}
                              | get_extended_data(UUID)
                              ]
                             ,JObj
                             ),
    kapi_resource:publish_originate_resp(ServerId, Resp).

-spec publish_originate_resp(kz_term:api_binary(), kz_json:object(), kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
publish_originate_resp('undefined', _JObj, _OriginateUUID, _UUID, _CtrlQ) ->
    lager:debug("not sending originate_resp server_id=undefined, originate_uuid=~s uuid=~s control_queue=~s", [_OriginateUUID, _UUID, _CtrlQ]);
publish_originate_resp(ServerId, JObj, OriginateUUID, UUID, CtrlQ) ->
    lager:debug("sending originate_resp server_id=~s, originate_uuid=~s uuid=~s control_queue=~s", [ServerId, OriginateUUID, UUID, CtrlQ]),
    Resp = kz_json:set_values([{<<"Event-Category">>, <<"resource">>}
                              ,{<<"Application-Response">>, <<"SUCCESS">>}
                              ,{<<"Event-Name">>, <<"originate_resp">>}
                              ,{<<"Call-ID">>, UUID}
                              ,{<<"Originate-UUID">>, OriginateUUID}
                              ,{<<"Control-Queue">>, CtrlQ}
                              | get_extended_data(UUID)
                              ]
                             ,JObj
                             ),
    kapi_resource:publish_originate_resp(ServerId, Resp).

-spec get_extended_data(kz_term:ne_binary()) -> kz_term:proplist().
get_extended_data(UUID) ->
    case ecallmgr_fs_channels:api_status(UUID) of
        {'error', _} -> [];
        {'ok', Data} -> Data
    end.

-spec start_control_process(state()) ->
          {'ok', state()} |
          {'error', any()}.
start_control_process(#state{originate_req=JObj
                            ,node=Node
                            ,controller_q=ControllerQ
                            ,server_id=ServerId
                            ,originate_uuid=OriginateUUID
                            ,uuid=UUID
                            }=State) ->
    Ctx = #{node => Node
           ,call_id => UUID
           ,fetch_id => OriginateUUID
           ,controller_q => ControllerQ
           ,initial_ccvs => kz_json:new()
           },
    case ecallmgr_call_control_manager:start_call_control(Ctx) of
        {'ok', CtrlPid} when is_pid(CtrlPid) ->
            lager:debug("started control pid ~p for uuid ~s", [CtrlPid, UUID]),
            {'ok', State#state{control_pid=CtrlPid}};
        {'error', _E}=E ->
            Error = <<"failed to preemptively start a call control process">>,
            _ = publish_error(Error, UUID, JObj, ServerId),
            E
    end.


-spec start_abandon_timer() -> reference().
start_abandon_timer() ->
    erlang:send_after(?REPLY_TIMEOUT, self(), 'abandon_originate').
