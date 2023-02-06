%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc Listener for reg_success, and reg_query AMQP requests
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_registrar).
-behaviour(gen_listener).

-export([start_link/0]).
-export([handle_reg_success/2
        ,handle_reg_query/2
        ,handle_reg_flush/2
        ,handle_fs_reg/2
        ]).
-export([lookup_contact/2
        ,lookup_original_contact/2
        ,lookup_registration/2
        ,lookup_proxy_path/2
        ,lookup_endpoint/2
        ,get_registration/2
        ]).
-export([summary/0, summary/1
        ,details/0, details/1, details/2
        ,flush/0, flush/1, flush/2
        ,sync/0
        ,count/0
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-ifdef(TEST).
-export([breakup_contact/1]).
-endif.

-include("ecallmgr.hrl").
-include_lib("kazoo_sip/include/kzsip_uri.hrl").

-elvis([{elvis_style, no_debug_call, disable}]).

-define(SERVER, ?MODULE).

-define(RESPONDERS, [{{?MODULE, 'handle_reg_query'}
                     ,[{<<"directory">>, <<"reg_query">>}]
                     }
                    ,{{?MODULE, 'handle_reg_success'}
                     ,[{<<"directory">>, <<"reg_success">>}]
                     }
                    ,{{?MODULE, 'handle_reg_flush'}
                     ,[{<<"directory">>, <<"reg_flush">>}]
                     }
                    ]).
-define(BINDINGS, [{'registration', [{'restrict_to',
                                      ['reg_query'
                                      ,'reg_flush'
                                      ,'reg_success'
                                      ]
                                     }
                                    ,'federate'
                                    ]}
                  ,{'self', []}
                  ]).
-define(REG_QUEUE_NAME, <<>>).
-define(REG_QUEUE_OPTIONS, []).
-define(REG_CONSUME_OPTIONS, []).
-define(EXPIRES_MISSING_VALUE, 0).

-record(state, {started = kz_time:now_s()
               ,queue :: kz_term:api_binary()
               }).
-type state() :: #state{}.

-record(registration, {account_db :: kz_term:api_binary() | '_'
                      ,account_id :: kz_term:api_binary() | '_'
                      ,account_name :: kz_term:api_binary() | '_'
                      ,account_realm :: kz_term:api_binary() | '_' | '$2'
                      ,authorizing_id :: kz_term:api_binary() | '_'
                      ,authorizing_type :: kz_term:api_binary() | '_'
                      ,bridge_uri :: kz_term:api_binary() | '_'
                      ,call_id :: kz_term:api_ne_binary() | '_'
                      ,contact :: kz_term:api_ne_binary() | '_'
                      ,expires = ?EXPIRES_MISSING_VALUE :: non_neg_integer() | '_' | '$1'
                      ,from_host :: kz_term:api_ne_binary() | '_'
                      ,from_user = <<"nouser">> :: kz_term:ne_binary() | '_'
                      ,id :: {kz_term:ne_binary(), kz_term:ne_binary() | '_'} | '_' | '$1'
                      ,initial = 'true' :: boolean() | '_'
                      ,initial_registration = kz_time:now_s() :: kz_time:gregorian_seconds() | '_'
                      ,last_registration = kz_time:now_s() :: kz_time:gregorian_seconds() | '_' | '$2'
                      ,network_ip :: kz_term:api_ne_binary() | '_'
                      ,network_port :: kz_term:api_ne_binary() | '_'
                      ,original_contact :: kz_term:api_ne_binary() | '_'
                      ,owner_id :: kz_term:api_binary() | '_'
                      ,presence_id :: kz_term:api_binary() | '_'
                      ,previous_contact :: kz_term:api_binary() | '_'
                      ,proxy :: kz_term:api_binary() | '_'
                      ,proxy_ip :: kz_term:api_binary() | '_'
                      ,proxy_port :: kz_term:api_integer() | '_'
                      ,proxy_proto :: kz_term:api_binary() | '_'
                      ,realm :: kz_term:api_ne_binary() | '_' | '$1'
                      ,register_overwrite_notify = 'false' :: boolean() | '_'
                      ,registrar_hostname :: kz_term:api_ne_binary() | '_'
                      ,registrar_node :: kz_term:api_ne_binary() | '_'
                      ,registrar_zone :: atom() | '_'
                      ,source_ip :: kz_term:api_binary() | '_'
                      ,source_port :: kz_term:api_binary() | '_'
                      ,suppress_unregister = 'true' :: boolean() | '_'
                      ,to_host :: kz_term:api_ne_binary() | '_'
                      ,to_user = <<"nouser">> :: kz_term:ne_binary() | '_'
                      ,user_agent :: kz_term:api_ne_binary() | '_'
                      ,username :: kz_term:api_ne_binary() | '_'
                      ,endpoint_token :: kz_term:api_ne_binary() | '_'
                      ,meta_id :: kz_term:api_ne_binary() | '_'
                      }).

-type registration() :: #registration{}.
-type registrations() :: [registration()].

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_listener:start_link({'local', ?SERVER}
                           ,?MODULE
                           ,[{'responders', ?RESPONDERS}
                            ,{'bindings', ?BINDINGS}
                            ,{'queue_name', ?REG_QUEUE_NAME}
                            ,{'queue_options', ?REG_QUEUE_OPTIONS}
                            ,{'consume_options', ?REG_CONSUME_OPTIONS}
                            ,{'auto_gc', 'false'}
                            ]
                           ,[]
                           ).

-spec handle_reg_success(kapi_registration:success(), kz_term:proplist()) -> 'ok'.
handle_reg_success(RegSuccess, _Props) ->
    'true' = kapi_registration:success_v(RegSuccess),
    _ = kz_log:put_callid(RegSuccess),
    Registration = create_registration(RegSuccess),
    insert_registration(Registration).

-spec handle_reg_query(kapi_registration:query_req(), kz_term:proplist()) -> 'ok'.
handle_reg_query(QueryJObj, Props) ->
    'true' = kapi_registration:query_req_v(QueryJObj),
    _ = kz_log:put_callid(QueryJObj),
    maybe_resp_to_query(QueryJObj, props:get_value('registrar_age', Props)).

-spec handle_reg_flush(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_reg_flush(JObj, _Props) ->
    'true' = kapi_registration:flush_v(JObj),
    Username = kz_json:get_value(<<"Username">>, JObj),
    Realm = get_realm(JObj),
    lager:debug("recv req to flush ~s @ ~s"
               ,[Username, Realm]
               ),
    flush(Username, Realm).

-spec handle_fs_reg(atom(), kzd_freeswitch:data()) -> 'ok'.
handle_fs_reg(Node, FSJObj) ->
    kz_log:put_callid(kzd_freeswitch:call_id(FSJObj)),

    {_, Req} = lists:foldl(fun collect_reg_success_props/2
                          ,{FSJObj
                           ,[{<<"Event-Timestamp">>, round(kz_time:now_s())}
                            ,{<<"FreeSWITCH-Nodename">>, kz_term:to_binary(Node)}
                            | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                            ]
                           }
                          ,kapi_registration:success_keys()
                          ),
    lager:debug("sending successful registration for ~s@~s"
               ,[props:get_value(<<"Username">>, Req)
                ,props:get_value(<<"Realm">>, Req)
                ]
               ),
    kz_amqp_worker:cast(Req, fun kapi_registration:publish_success/1).

collect_reg_success_props(<<"Contact">>=Key, {FSJObj, Acc}) ->
    {FSJObj, [{Key, get_fs_contact(FSJObj)} | Acc]};
collect_reg_success_props(Key, {FSJObj, Acc}) ->
    case kz_json:get_first_defined([kz_term:to_lower_binary(Key), Key], FSJObj) of
        'undefined' -> {FSJObj, Acc};
        Value -> {FSJObj, [{Key, Value} | Acc]}
    end.

-spec lookup_endpoint(binary(), binary()) ->
          {'ok', kz_term:proplist()} |
          {'error', 'not_found'}.
lookup_endpoint(<<>>, _AccountId) -> {'error', 'not_found'};
lookup_endpoint(_EndpointId, <<>>) -> {'error', 'not_found'};
lookup_endpoint(<<EndpointId/binary>>, <<AccountId/binary>>) ->
    MatchSpec = #registration{account_id = AccountId
                             ,authorizing_id = EndpointId
                             ,_ = '_'
                             },

    case ets:match_object(?MODULE, MatchSpec) of
        [] ->
            {'error', 'not_found'};
        [#registration{endpoint_token='undefined'}] ->
            {'ok', []};
        [#registration{endpoint_token=Token}] ->
            {'ok', [{'token', Token}]}
    end.

-spec lookup_proxy_path(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_term:api_ne_binary(), kz_term:proplist()} |
          {'ok', [{kz_term:api_ne_binary(), kz_term:proplist()}]} |
          {'error', 'not_found'}.
lookup_proxy_path(<<>>, _Username) -> {'error', 'not_found'};
lookup_proxy_path(_Realm, <<>>) -> {'error', 'not_found'};
lookup_proxy_path(<<Realm/binary>>, <<Username/binary>>) ->
    MatchSpec = #registration{account_id = Realm
                             ,authorizing_id = Username
                             ,_ = '_'
                             },
    case ets:match_object(?MODULE, MatchSpec) of
        [] -> lookup_meta_path(Realm, Username);
        [#registration{proxy = Proxy}=Reg] -> {'ok', Proxy, proxy_vars(Reg)}
    end.

-spec lookup_meta_path(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', [{kz_term:api_ne_binary(), kz_term:proplist()}]} |
          {'error', 'not_found'}.
lookup_meta_path(<<Realm/binary>>, <<Username/binary>>) ->
    MatchSpec = #registration{account_id = Realm
                             ,meta_id = Username
                             ,_ = '_'
                             },
    case ets:match_object(?MODULE, MatchSpec) of
        [] -> {'error', 'not_found'};
        Regs -> {ok, [{Proxy, proxy_vars(Reg)} || #registration{proxy = Proxy}=Reg <- Regs]}
    end.

-spec proxy_vars_options(registration()) -> map().
proxy_vars_options(Reg) ->
    Funs = [fun proxy_var_option_token/2
           ],
    lists:foldl(proxy_vars_options_fun(Reg), #{}, Funs).

proxy_vars_options_fun(Reg) ->
    fun(F, Acc) ->
            F(Reg, Acc)
    end.

-spec proxy_var_option_token(registration(), map()) -> map().
proxy_var_option_token(#registration{endpoint_token='undefined'}, Options) -> Options;
proxy_var_option_token(#registration{}, Options) -> Options#{token_registration => 'true'}.

-spec proxy_vars(registration()) -> kz_term:proplist().
proxy_vars(Reg) ->
    proxy_vars(to_props(Reg), proxy_vars_options(Reg)).

-spec proxy_vars(kz_term:proplist(), map()) -> kz_term:proplist().
proxy_vars(Props, Options) ->
    lists:usort(lists:foldl(proxy_vars_fun(Options), [], Props)).

proxy_vars_fun(Options) ->
    fun(Prop, Acc) ->
            proxy_vars_fold(Prop, Acc, Options)
    end.

-spec proxy_vars_fold({kz_term:ne_binary(), term()}, kz_term:proplist(), map()) -> kz_term:proplist().
proxy_vars_fold({<<"Proxy-Protocol">>, Proto}, Props, _Options) ->
    case kz_term:to_lower_binary(Proto) of
        <<"ws", _/binary>> ->
            [{<<"Media-Webrtc">>, 'true'}
            ,{<<"RTCP-MUX">>, 'true'}
            | Props
            ];
        _ -> Props
    end;
proxy_vars_fold({<<"AOR">>, AOR}, Props, #{token_registration := 'true'}) ->
    [{<<"SIP-Invite-To-URI">>, AOR}
    ,{<<"KAZOO-AOR">>, AOR}
    | Props
    ];
proxy_vars_fold(_Prop , Props, _Options) -> Props.

-spec lookup_contact(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_term:ne_binary(), kz_term:proplist()} |
          {'error', 'not_found'}.
lookup_contact(<<>>, _Username) -> {'error', 'not_found'};
lookup_contact(_Realm, <<>>) -> {'error', 'not_found'};
lookup_contact(<<Realm/binary>>, <<Username/binary>>) ->
    case get_registration(Realm, Username) of
        'undefined' -> fetch_contact(Username, Realm);
        #registration{contact=Contact}=Reg ->
            lager:info("found user ~s@~s contact ~s"
                      ,[Username, Realm, Contact]
                      ),
            {'ok', Contact, contact_vars(to_props(Reg))}
    end.

-spec contact_vars(kz_term:proplist()) -> kz_term:proplist().
contact_vars(Props) ->
    lists:usort(lists:foldl(fun contact_vars_fold/2, [], Props)).

-spec contact_vars_fold({kz_term:ne_binary(), term()}, kz_term:proplist()) -> kz_term:proplist().
contact_vars_fold({<<"Proxy-Protocol">>, Proto}, Props) ->
    case kz_term:to_lower_binary(Proto) of
        <<"ws", _/binary>> ->
            [{<<"Media-Webrtc">>, 'true'}
            ,{<<"RTCP-MUX">>, 'true'}
            | Props
            ];
        _ -> Props
    end;
contact_vars_fold({<<"Proxy-Path">>, ProxyPath}, Props) ->
    [{<<"Proxy-Path">>, ProxyPath} | Props];
contact_vars_fold(_ , Props) -> Props.

-spec lookup_original_contact(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_term:ne_binary()} |
          {'error', 'not_found'}.
lookup_original_contact(Realm, Username) ->
    case kz_term:is_empty(Realm)
        orelse kz_term:is_empty(Username)
    of
        'true' -> {'error', 'not_found'};
        'false' ->
            lookup_original_contact_registration(Realm, Username)
    end.

lookup_original_contact_registration(Realm, Username) ->
    case get_registration(Realm, Username) of
        #registration{original_contact=Contact} ->
            lager:info("found user ~s@~s original contact ~s"
                      ,[Username, Realm, Contact]
                      ),
            {'ok', Contact};
        'undefined' -> fetch_original_contact(Username, Realm)
    end.

-spec lookup_registration(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_json:object()} |
          {'error', 'not_found'}.
lookup_registration(Realm, Username) ->
    case get_registration(Realm, Username) of
        #registration{}=Registration ->
            {'ok', kz_json:from_list(to_props(Registration))};
        'undefined' -> fetch_registration(Username, Realm)
    end.

-spec get_registration(kz_term:ne_binary(), kz_term:ne_binary()) -> 'undefined' | registration().
get_registration(Realm, Username) ->
    case ets:lookup(?MODULE, registration_id(Username, Realm)) of
        [#registration{}=Registration] -> Registration;
        _ -> 'undefined'
    end.

-spec summary() -> 'ok'.
summary() ->
    MatchSpec =
        [{#registration{_ = '_'}
         ,[]
         ,['$_']
         }
        ],
    print_summary(ets:select(?MODULE, MatchSpec, 1)).

-spec summary(kz_term:text()) -> 'ok'.
summary(Realm) when not is_binary(Realm) ->
    summary(kz_term:to_binary(Realm));
summary(Realm) ->
    R = kz_term:to_lower_binary(Realm),
    MatchSpec =
        [{#registration{realm = '$1'
                       ,account_realm = '$2'
                       ,_ = '_'
                       }
         ,[{'orelse'
           ,{'=:=', '$1', {'const', R}}
           ,{'=:=', '$2', {'const', R}}
           }
          ]
         ,['$_']
         }
        ],
    print_summary(ets:select(?MODULE, MatchSpec, 1)).

-spec details() -> 'ok'.
details() ->
    MatchSpec =
        [{#registration{_ = '_'}
         ,[]
         ,['$_']
         }
        ],
    print_details(ets:select(?MODULE, MatchSpec, 1)).

-spec details(kz_term:text()) -> 'ok'.
details(User) when not is_binary(User) ->
    details(kz_term:to_binary(User));
details(User) ->
    case binary:split(User, <<"@">>) of
        [Username, Realm] -> details(Username, Realm);
        _Else ->
            Realm = kz_term:to_lower_binary(User),
            MatchSpec =
                [{#registration{realm = '$1'
                               ,account_realm = '$2'
                               ,_ = '_'
                               }
                 ,[{'orelse'
                   ,{'=:=', '$1', {'const', Realm}}
                   ,{'=:=', '$2', {'const', Realm}}
                   }
                  ]
                 ,['$_']
                 }
                ],
            print_details(ets:select(?MODULE, MatchSpec, 1))
    end.

-spec details(kz_term:text(), kz_term:text()) -> 'ok'.
details(Username, Realm) when not is_binary(Username) ->
    details(kz_term:to_binary(Username), Realm);
details(Username, Realm) when not is_binary(Realm) ->
    details(Username, kz_term:to_binary(Realm));
details(Username, Realm) ->
    Id =  registration_id(Username, Realm),
    MatchSpec =
        [{#registration{id = '$1', _ = '_'}
         ,[{'=:=', '$1', {'const', Id}}]
         ,['$_']
         }
        ],
    print_details(ets:select(?MODULE, MatchSpec, 1)).

-spec sync() -> 'ok'.
sync() ->
    gen_server:cast(?SERVER, 'registrar_sync').

-spec flush() -> 'ok'.
flush() ->
    gen_server:cast(?SERVER, 'flush').

-spec flush(kz_term:text()) -> 'ok'.
flush(Realm) when not is_binary(Realm)->
    flush(kz_term:to_binary(Realm));
flush(Realm) ->
    case binary:split(Realm, <<"@">>) of
        [Username, Realm] -> flush(Username, Realm);
        _Else -> gen_server:cast(?SERVER, {'flush', Realm})
    end.

-spec flush(kz_term:text() | 'undefined', kz_term:text()) -> 'ok'.
flush('undefined', Realm) ->
    flush(Realm);
flush(Username, Realm) when not is_binary(Realm) ->
    flush(Username, kz_term:to_binary(Realm));
flush(Username, Realm) when not is_binary(Username) ->
    flush(kz_term:to_binary(Username), Realm);
flush(Username, Realm) ->
    gen_server:cast(?SERVER, {'flush', Username, Realm}).

-spec count() -> non_neg_integer().
count() -> ets:info(?MODULE, 'size').

%%%=============================================================================
%%% gen_listener callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    process_flag('trap_exit', 'true'),
    lager:debug("starting new ecallmgr registrar"),
    _ = ets:new(?MODULE, ['set', 'protected', 'named_table', {'keypos', #registration.id}]),
    erlang:send_after(2 * ?MILLISECONDS_IN_SECOND, self(), 'expire'),
    gproc:reg({'p', 'l', ?REGISTER_SUCCESS_REG}),
    {'ok', #state{}}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Msg, _From, State) ->
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast('registrar_sync', #state{queue=Q}=State) ->
    Payload = kz_api:default_headers(Q, ?APP_NAME, ?APP_VERSION),
    _ = kz_amqp_worker:cast(Payload, fun kapi_registration:publish_sync/1),
    {'noreply', State};
handle_cast({'insert_registration', Registration}, State) ->
    kz_log:put_callid(Registration#registration.call_id),
    _ = ets:insert(?MODULE, Registration#registration{initial='false'}),
    {'noreply', State};
handle_cast({'update_registration', {Username, Realm}=Id, Props}, State) ->
    lager:debug("updated registration ~s@~s", [Username, Realm]),
    _ = ets:update_element(?MODULE, Id, Props),
    {'noreply', State};
handle_cast({'delete_registration'
            ,#registration{id=Id
                          ,call_id=CallId
                          }=Reg
            }
           ,State) ->
    kz_log:put_callid(CallId),
    _ = kz_process:spawn(fun maybe_send_deregister_notice/1, [Reg]),
    ets:delete(?MODULE, Id),
    {'noreply', State};
handle_cast('flush', State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    _ = ets:delete_all_objects(?MODULE),
    {'noreply', State};
handle_cast({'flush', Realm}, State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    R = kz_term:to_lower_binary(Realm),
    MatchSpec = [{#registration{realm = '$1'
                               ,account_realm = '$2'
                               ,_ = '_'
                               }
                 ,[{'orelse', {'=:=', '$1', {'const', R}}
                   ,{'=:=', '$2', {'const', R}}}
                  ]
                 ,['true']
                 }],
    NumberDeleted = ets:select_delete(?MODULE, MatchSpec),
    lager:debug("removed ~p expired registrations", [NumberDeleted]),
    ecallmgr_fs_nodes:flush(),
    {'noreply', State};
handle_cast({'flush', Username, Realm}, State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    _ = ets:delete(?MODULE, registration_id(Username, Realm)),
    {'noreply', State};
handle_cast({'gen_listener', {'created_queue', Q}}, State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    {'noreply', State#state{queue=Q}};
handle_cast({'gen_listener',{'is_consuming', 'true'}}, #state{queue=Q}=State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    kapi_registration:publish_sync(kz_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)),
    {'noreply', State};
handle_cast(_Msg, State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info('expire', State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    _ = expire_objects(),
    _ = erlang:send_after(2 * ?MILLISECONDS_IN_SECOND, self(), 'expire'),
    {'noreply', State};
handle_info(?REGISTER_SUCCESS_MSG(Node, Props), State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    _ = kz_process:spawn(fun handle_fs_reg/2, [Node, Props]),
    {'noreply', State};
handle_info(_Info, State) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling AMQP event objects
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> gen_listener:handle_event_return().
handle_event(_JObj, #state{started=Started}) ->
    {'reply', [{'registrar_age', kz_time:now_s() - Started}]}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_listener' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_listener' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), any()) -> 'ok'.
terminate(_Reason, _) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    lager:debug("ecallmgr registrar ~p termination", [_Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec insert_registration(registration()) -> 'ok'.
insert_registration(#registration{expires=0}=Registration) ->
    lager:info("deleting registration ~s@~s with contact ~s"
              ,[Registration#registration.username
               ,Registration#registration.realm
               ,Registration#registration.contact
               ]
              ),
    gen_server:cast(?SERVER, {'delete_registration', Registration});
insert_registration(#registration{initial='true'}=Registration) ->
    gen_server:cast(?SERVER, {'insert_registration', Registration}),
    lager:info("inserted registration ~s@~s with contact ~s"
              ,[Registration#registration.username
               ,Registration#registration.realm
               ,Registration#registration.contact
               ]
              ),
    initial_registration(Registration);
insert_registration(#registration{}=Registration) ->
    gen_server:cast(?SERVER, {'insert_registration', Registration}),
    lager:debug("updated registration ~s@~s with contact ~s"
               ,[Registration#registration.username
                ,Registration#registration.realm
                ,Registration#registration.contact
                ]).

-spec fetch_registration(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_json:object()} |
          {'error', 'not_found'}.
fetch_registration(Username, Realm) ->
    Reg = [{<<"Username">>, Username}
          ,{<<"Realm">>, Realm}
          ,{<<"Fields">>, []} % will fetch all fields
          | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    case query_for_registration(Reg) of
        {'ok', JObjs} ->
            find_newest_fetched_registration(Username, Realm, JObjs);
        _Else ->
            lager:info("registration query for user ~s@~s failed: ~p", [Username, Realm, _Else]),
            {'error', 'not_found'}
    end.

-spec query_for_registration(kz_term:api_terms()) ->
          {'ok', kz_json:objects()} |
          {'error', any()}.
query_for_registration(Reg) ->
    kz_amqp_worker:call_collect(Reg
                               ,fun kapi_registration:publish_query_req/1
                               ,{'ecallmgr', 'true'}
                               ,2 * ?MILLISECONDS_IN_SECOND
                               ).

-spec find_newest_fetched_registration(kz_term:ne_binary(), kz_term:ne_binary(), kz_json:objects()) ->
          {'ok', kz_json:object()} |
          {'error', 'not_found'}.
find_newest_fetched_registration(Username, Realm, JObjs) ->
    Registrations =
        lists:flatten(
          [Replies
           || JObj <- JObjs,
              kz_api:event_name(JObj) =:= <<"reg_query_resp">>
                  andalso kapi_registration:query_resp_v(JObj),
              (Replies = kz_json:get_list_value(<<"Fields">>, JObj, [])) =/= []
          ]
         ),
    case lists:sort(fun sort_fetched_registrations/2, Registrations) of
        [Registration|_] ->
            lager:info("fetched user ~s@~s registration", [Username, Realm]),
            _ = maybe_insert_fetched_registration(Registration),
            {'ok', Registration};
        _Else ->
            lager:info("registration query for user ~s@~s returned an empty result"
                      ,[Username, Realm]
                      ),
            {'error', 'not_found'}
    end.

-spec maybe_insert_fetched_registration(kz_json:object()) -> 'ok'.
maybe_insert_fetched_registration(JObj) ->
    case kapps_config:get_boolean(?APP_NAME, <<"insert_fetched_registration_locally">>, 'false') of
        'false' -> 'ok';
        'true' -> insert_fetched_registration(JObj)
    end.

-spec insert_fetched_registration(kz_json:object()) -> 'ok'.
insert_fetched_registration(JObj) ->
    %% NOTE: create_registration will pad the registration which
    %%   will cause it to live longer on this server.  If the re-registration
    %%   to the other zone changes the contact this zone will continue to
    %%   use a stale value (also an issue if it re-registers before expiration)
    %%   unless it also expires here at close to the same time (preferably before).
    Expires = kz_json:get_integer_value(<<"Expires">>, JObj, ?EXPIRES_MISSING_VALUE)
        - ?EXPIRES_DEVIATION_TIME,
    Registration = create_registration(JObj),
    insert_registration(Registration#registration{expires=Expires}).

-spec sort_fetched_registrations(kz_json:object(), kz_json:object()) -> boolean().
sort_fetched_registrations(A, B) ->
    kz_json:get_integer_value(<<"Event-Timestamp">>, B) =<
        kz_json:get_integer_value(<<"Event-Timestamp">>, A).

-spec fetch_contact(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_term:ne_binary()} |
          {'error', 'not_found'}.
fetch_contact(Username, Realm) ->
    case fetch_registration(Username, Realm) of
        {'ok', JObj} ->
            Contact = kz_json:get_ne_binary_value(<<"Contact">>, JObj),
            lager:info("found user ~s@~s contact ~s via fetch"
                      ,[Username, Realm, Contact]
                      ),
            {'ok', Contact, contact_vars(kz_json:to_proplist(JObj))};
        {'error', _R}=Error ->
            lager:info("original contact query for user ~s@~s failed: ~p", [Username, Realm, _R]),
            Error
    end.

-spec fetch_original_contact(kz_term:ne_binary(), kz_term:ne_binary()) ->
          {'ok', kz_term:ne_binary()} |
          {'error', 'not_found'}.
fetch_original_contact(Username, Realm) ->
    case fetch_registration(Username, Realm) of
        {'ok', JObj} ->
            Contact = kz_json:get_value(<<"Original-Contact">>, JObj),
            lager:info("found user ~s@~s original contact ~s via query"
                      ,[Username, Realm, Contact]
                      ),
            {'ok', Contact};
        {'error', _R}=Error ->
            lager:info("original contact query for user ~s@~s failed: ~p", [Username, Realm, _R]),
            Error
    end.

-spec expire_objects() -> 'ok'.
expire_objects() ->
    Now = kz_time:now_s(),
    MatchSpec = [{#registration{expires = '$1'
                               ,last_registration = '$2'
                               , _ = '_'
                               }
                 ,[{'>', {'const', Now}, {'+', '$1', '$2'}}]
                 ,['$_']
                 }
                ],
    expire_object(ets:select(?MODULE, MatchSpec, 1)).

-spec expire_object(any()) -> 'ok'.
expire_object('$end_of_table') -> 'ok';
expire_object({[#registration{id=Id}=Reg], Continuation}) ->
    _ = kz_process:spawn(fun maybe_send_deregister_notice/1, [Reg]),
    _ = ets:delete(?MODULE, Id),
    expire_object(ets:select(Continuation)).

-spec maybe_resp_to_query(kapi_registration:query_req(), integer()) -> 'ok'.
maybe_resp_to_query(QueryJObj, RegistrarAge) ->
    case kz_api:node(QueryJObj) =:= kz_term:to_binary(node())
        andalso kz_api:app_name(QueryJObj) =:= ?APP_NAME
    of
        'false' -> resp_to_query(QueryJObj, RegistrarAge);
        'true' ->
            Resp = [{<<"Msg-ID">>, kz_api:msg_id(QueryJObj)}
                   ,{<<"Registrar-Age">>, RegistrarAge}
                   | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],
            kapi_registration:publish_query_err(kz_api:server_id(QueryJObj), Resp)
    end.

-spec build_query_spec(kapi_registration:query_req(), boolean()) -> ets:match_spec().
build_query_spec(QueryJObj, CountOnly) ->
    {SelectFormat, QueryFormat} =
        build_query_spec_by_realm(QueryJObj, get_lower_realm(QueryJObj)),

    ResultFormat = case CountOnly of
                       'true' -> 'true';
                       'false' -> '$_'
                   end,

    [{SelectFormat
     ,[QueryFormat]
     ,[ResultFormat]
     }
    ].

build_query_spec_by_realm(_QueryJObj, <<"all">>) ->
    {#registration{_='_'}, {'=:=', 'undefined', 'undefined'}};
build_query_spec_by_realm(QueryJObj, Realm) ->
    build_query_spec_maybe_username(QueryJObj, Realm).

-spec build_query_spec_maybe_username(kapi_registration:query_req(), kz_term:ne_binary()) -> tuple().
build_query_spec_maybe_username(QueryJObj, Realm) ->
    case kz_json:get_value(<<"Username">>, QueryJObj) of
        'undefined' ->
            {#registration{realm = '$1'
                          ,account_realm = '$2'
                          ,_ = '_'
                          }
            ,{'orelse', {'=:=', '$1', {'const', Realm}}
             ,{'=:=', '$2', {'const', Realm}}
             }
            };
        Username ->
            Id = registration_id(Username, Realm),
            {#registration{id = '$1', _ = '_'}
            ,{'=:=', '$1', {'const', Id}}
            }
    end.

-spec resp_to_query(kapi_registration:query_req(), integer()) -> 'ok'.
resp_to_query(QueryJObj, RegistrarAge) ->
    CountOnly = kz_json:is_true(<<"Count-Only">>, QueryJObj, 'false'),

    SelectFun = query_select_fun(CountOnly),

    MatchSpec = build_query_spec(QueryJObj, CountOnly),

    resp_to_query(QueryJObj, RegistrarAge, SelectFun(?MODULE, MatchSpec)).

query_select_fun('true') -> fun ets:select_count/2;
query_select_fun('false') -> fun ets:select/2.

resp_to_query(QueryJObj, RegistrarAge, []) ->
    Resp = [{<<"Msg-ID">>, kz_api:msg_id(QueryJObj)}
           ,{<<"Registrar-Age">>, RegistrarAge}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kapi_registration:publish_query_err(kz_api:server_id(QueryJObj), Resp);
resp_to_query(QueryJObj, RegistrarAge, [_|_]=Registrations) ->
    Fields = kz_json:get_list_value(<<"Fields">>, QueryJObj, []),
    Resp = [{<<"Msg-ID">>, kz_api:msg_id(QueryJObj)}
           ,{<<"Registrar-Age">>, RegistrarAge}
           ,{<<"Fields">>, [filter(Fields, kz_json:from_list(to_props(Registration)))
                            || Registration <- Registrations
                           ]
            }
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kapi_registration:publish_query_resp(kz_api:server_id(QueryJObj), Resp);
resp_to_query(QueryJObj, RegistrarAge, Count) when is_integer(Count) ->
    Resp = [{<<"Msg-ID">>, kz_api:msg_id(QueryJObj)}
           ,{<<"Registrar-Age">>, RegistrarAge}
           ,{<<"Fields">>, []}
           ,{<<"Count">>, Count}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kapi_registration:publish_query_resp(kz_api:server_id(QueryJObj), Resp).

-spec filter(kz_json:path(), kz_json:object()) -> kz_json:object().
filter([], JObj) -> JObj;
filter(Fields, JObj) ->
    {FilteredFields, _} = lists:foldl(fun filter_field/2, {[], JObj}, Fields),
    kz_json:from_list(FilteredFields).

filter_field(Field, {Acc, RegistrationJObj}) ->
    {[{Field, kz_json:get_value(Field, RegistrationJObj)} | Acc]
    ,RegistrationJObj
    }.

-spec registration_id(kz_term:ne_binary(), kz_term:ne_binary()) -> {kz_term:ne_binary(), kz_term:ne_binary()}.
registration_id(Username, Realm) ->
    {kz_term:to_lower_binary(Username), kz_term:to_lower_binary(Realm)}.

-spec create_registration(kapi_registration:success()) -> registration().
create_registration(RegSuccess) ->
    Username = kz_json:get_value(<<"Username">>, RegSuccess),
    Realm = get_realm(RegSuccess),
    Reg = existing_or_new_registration(Username, Realm),

    Proxy = kz_json:get_value(<<"Proxy-Path">>, RegSuccess, Reg#registration.proxy),
    ProxyIP = kz_json:get_value(<<"Proxy-IP">>, RegSuccess, Reg#registration.proxy_ip),
    ProxyPort = kz_json:get_integer_value(<<"Proxy-Port">>, RegSuccess, Reg#registration.proxy_port),
    ProxyProto = kz_json:get_value(<<"Proxy-Protocol">>, RegSuccess, Reg#registration.proxy_proto),
    OriginalContact =
        kz_json:get_first_defined([<<"Original-Contact">>
                                  ,<<"Contact">>
                                  ]
                                 ,RegSuccess
                                 ,Reg#registration.original_contact
                                 ),
    Expires =
        ecallmgr_util:maybe_add_expires_deviation(
          kz_json:get_integer_value(<<"Expires">>, RegSuccess, Reg#registration.expires)
         ),
    RegistrarNode =
        kz_json:get_first_defined([<<"Registrar-Node">>
                                  ,<<"FreeSWITCH-Nodename">>
                                  ,<<"Node">>
                                  ]
                                 ,RegSuccess
                                 ,Reg#registration.registrar_node
                                 ),
    RegistrarHostname =
        kz_json:get_first_defined([<<"Hostname">>
                                  ,<<"Registrar-Hostname">>
                                  ]
                                 ,RegSuccess
                                 ,Reg#registration.registrar_hostname
                                 ),
    RegistrarZone =
        kz_term:to_atom(kz_json:get_ne_binary_value(<<"AMQP-Broker-Zone">>
                                                   ,RegSuccess
                                                   ,kz_nodes:local_zone()
                                                   )
                       ,'true'
                       ),
    augment_registration(Reg#registration{bridge_uri=bridge_uri(OriginalContact, Proxy, Username, Realm)
                                         ,call_id=kz_api:call_id(RegSuccess, Reg#registration.call_id)
                                         ,contact=fix_contact(OriginalContact)
                                         ,expires=Expires
                                         ,from_host=get_realm(<<"From-Host">>, RegSuccess)
                                         ,from_user=kz_json:get_value(<<"From-User">>, RegSuccess, Reg#registration.from_user)
                                         ,initial=kz_json:is_true(<<"First-Registration">>, RegSuccess, Reg#registration.initial)
                                         ,initial_registration=kz_json:get_integer_value(<<"Initial-Registration">>, RegSuccess, Reg#registration.initial_registration)
                                         ,last_registration=kz_json:get_integer_value(<<"Last-Registration">>, RegSuccess, Reg#registration.last_registration)
                                         ,network_ip=kz_json:get_value(<<"Network-IP">>, RegSuccess, Reg#registration.network_ip)
                                         ,network_port=kz_json:get_value(<<"Network-Port">>, RegSuccess, Reg#registration.network_port)
                                         ,original_contact=OriginalContact
                                         ,previous_contact=kz_json:get_value(<<"Previous-Contact">>, RegSuccess, Reg#registration.previous_contact)
                                         ,proxy=Proxy
                                         ,proxy_ip=ProxyIP
                                         ,proxy_port=ProxyPort
                                         ,proxy_proto=ProxyProto
                                         ,realm=Realm
                                         ,registrar_hostname=RegistrarHostname
                                         ,registrar_node=RegistrarNode
                                         ,registrar_zone=RegistrarZone
                                         ,source_ip=kz_json:get_value(<<"Source-IP">>, RegSuccess)
                                         ,source_port=kz_json:get_value(<<"Source-Port">>, RegSuccess)
                                         ,to_host=get_realm(<<"To-Host">>, RegSuccess)
                                         ,to_user=kz_json:get_value(<<"To-User">>, RegSuccess, Reg#registration.to_user)
                                         ,user_agent=kz_json:get_value(<<"User-Agent">>, RegSuccess, Reg#registration.user_agent)
                                         ,username=Username
                                         }
                        ,RegSuccess
                        ).

-spec get_realm(kz_json:key(), kz_json:object()) -> kz_term:ne_binary().
get_realm(Key, JObj) ->
    case kz_json:get_ne_binary_value(Key, JObj) of
        'undefined' -> ?DEFAULT_REALM;
        Realm -> Realm
    end.

endpoint_from_token('undefined') -> kz_json:new();
endpoint_from_token(EndpointToken) ->
    endpoint_from_token_ccvs(EndpointToken, kz_auth:validate_token(EndpointToken)).

endpoint_from_token_ccvs(_Token, {'error', _}) -> kz_json:new();
endpoint_from_token_ccvs(Token, {'ok', Claims}) ->
    EndpointId = kz_auth_claims:id(Claims),
    AccountId = kz_auth_claims:account_id(Claims),
    Result = kz_endpoint:get(EndpointId, AccountId, [{'token', Token}]),
    endpoint_from_token_ccvs(Result).

endpoint_from_token_ccvs({'error', _}) -> kz_json:new();
endpoint_from_token_ccvs({'ok', Endpoint}) ->
    Props = [{<<"Owner-ID">>, kzd_endpoint:owner_id(Endpoint)}
            ,{<<"Account-Realm">>, kzd_endpoint:account_realm(Endpoint)}
            ,{<<"Account-Name">>, kzd_endpoint:account_name(Endpoint)}
            ,{<<"Presence-ID">>, kzd_endpoint:presence_id(Endpoint)}
            ,{<<"Endpoint-Meta-ID">>, kzd_endpoint:meta_id(Endpoint)}
            ],
    kz_json:from_list(Props).

-spec augment_registration(registration(), kz_json:object()) -> registration().
augment_registration(Reg, JObj) ->
    CCVs = kz_json:get_json_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new()),
    EndpointToken = kz_json:get_ne_binary_value(<<"Endpoint-Token">>, CCVs),
    EndpointCCVsFromToken = endpoint_from_token(EndpointToken),

    FindFun = fun(Key, Default) -> kz_json:find(Key, [JObj, CCVs, EndpointCCVsFromToken], Default) end,

    AccountId = FindFun(<<"Account-ID">>, Reg#registration.account_id),

    SuppressUnregister =
        kz_term:is_true(
          case FindFun(<<"Suppress-Unregister-Notifications">>, 'undefined') of
              'undefined' ->
                  FindFun(<<"Suppress-Unregister-Notify">>, Reg#registration.suppress_unregister);
              Else -> Else
          end
         ),

    OverwriteNotify =
        kz_term:is_true(
          FindFun(<<"Register-Overwrite-Notify">>, Reg#registration.register_overwrite_notify)
         ),

    Reg#registration{account_db=kzs_util:format_account_db(AccountId)
                    ,account_id=AccountId
                    ,account_name=FindFun(<<"Account-Name">>, Reg#registration.account_name)
                    ,account_realm=FindFun(<<"Account-Realm">>, Reg#registration.account_realm)
                    ,authorizing_id=FindFun(<<"Authorizing-ID">>, Reg#registration.authorizing_id)
                    ,authorizing_type=FindFun(<<"Authorizing-Type">>, Reg#registration.authorizing_type)
                    ,owner_id=FindFun(<<"Owner-ID">>, Reg#registration.owner_id)
                    ,presence_id=FindFun(<<"Presence-ID">>, Reg#registration.presence_id)
                    ,register_overwrite_notify=OverwriteNotify
                    ,suppress_unregister=SuppressUnregister
                    ,endpoint_token=EndpointToken
                    ,meta_id=FindFun(<<"Endpoint-Meta-ID">>, Reg#registration.meta_id)
                    }.

-spec fix_contact(kz_term:api_binary()) -> kz_term:api_binary().
fix_contact('undefined') -> 'undefined';
fix_contact(Contact) ->
    binary:replace(Contact, [<<"<">>, <<">">>], <<>>, ['global']).

-spec bridge_uri(kz_term:api_binary(), kz_term:api_binary(), binary(), binary()) -> kz_term:api_binary().
bridge_uri(_Contact, 'undefined', _, _) -> 'undefined';
bridge_uri('undefined', _Proxy, _, _) -> 'undefined';
bridge_uri(Contact, Proxy, Username, Realm) ->
    [#uri{opts = ContactOptions}=UriContact] = kzsip_uri:uris(Contact),
    [#uri{}=UriProxy] = kzsip_uri:uris(Proxy),
    Scheme = UriContact#uri.scheme,
    Options = #{uri_contact => UriContact
               ,uri_proxy => UriProxy
               },
    BridgeUriOptions = bridge_uri_options(Options),
    BridgeUri = #uri{scheme=Scheme
                    ,user=Username
                    ,domain=Realm
                    ,opts= ContactOptions ++ BridgeUriOptions
                    },
    kzsip_uri:ruri(BridgeUri).

-spec bridge_uri_options(map()) -> kz_term:proplist().
bridge_uri_options(Options) ->
    Routines = [fun bridge_uri_path/2
               ],
    lists:foldl(fun(Fun, Acc) -> Fun(Options, Acc) end, [], Routines).

-spec bridge_uri_path(map(), kz_term:proplist()) -> kz_term:proplist().
bridge_uri_path(#{uri_proxy := UriProxy}, Acc) ->
    #uri{opts = Options, ext_opts = ExtraOptions} = UriProxy,
    UriOptions = Options ++ ExtraOptions,
    Uri = UriProxy#uri{opts = UriOptions, ext_opts = []},
    [{<<"fs_path">>, list_to_binary(["<", kzsip_uri:ruri(Uri), ">"])} | Acc].

-spec existing_or_new_registration(kz_term:ne_binary(), kz_term:ne_binary()) -> registration().
existing_or_new_registration(Username, Realm) ->
    case ets:lookup(?MODULE, registration_id(Username, Realm)) of
        [#registration{contact=Contact}=Reg] ->
            Reg#registration{last_registration=kz_time:now_s()
                            ,previous_contact=Contact
                            };
        _Else ->
            lager:debug("new registration ~s@~s", [Username, Realm]),
            #registration{id=registration_id(Username, Realm)}
    end.

-spec initial_registration(registration()) -> 'ok'.
initial_registration(#registration{}=Reg) ->
    Routines = [fun maybe_query_authn/1
               ,fun maybe_send_register_notice/1
               ,fun maybe_registration_notify/1
               ],
    _ = lists:foldl(fun(F, R) -> F(R) end, Reg, Routines),
    'ok'.

-spec maybe_query_authn(registration()) -> registration().
maybe_query_authn(#registration{account_id=AccountId
                               ,authorizing_id=AuthorizingId
                               }=Reg
                 ) ->
    case kz_term:is_empty(AccountId)
        orelse kz_term:is_empty(AuthorizingId)
    of
        'true' -> query_authn(Reg);
        'false' -> Reg
    end.

-spec query_authn(registration()) -> registration().
query_authn(#registration{realm=Realm
                         ,username=Username
                         }=Reg
           ) ->
    case kz_cache:peek_local(?ECALLMGR_AUTH_CACHE, ?CREDS_KEY(Realm, Username)) of
        {'error', 'not_found'} -> fetch_authn(Reg);
        {'ok', JObj} ->
            update_registration(
              augment_registration(Reg, JObj)
             )
    end.

-spec fetch_authn(registration()) -> registration().
fetch_authn(#registration{call_id=CallId
                         ,from_host=FromHost
                         ,from_user=FromUser
                         ,network_ip=NetworkIP
                         ,network_port=NetworkPort
                         ,realm=Realm
                         ,registrar_node=Node
                         ,to_host=ToHost
                         ,to_user=ToUser
                         ,username=Username
                         }=Reg
           ) ->
    lager:debug("looking up credentials of ~s@~s", [Username, Realm]),
    Req = [{<<"Auth-Realm">>, Realm}
          ,{<<"Auth-User">>, Username}
          ,{<<"Call-ID">>, CallId}
          ,{<<"From">>, <<FromUser/binary, "@", FromHost/binary>>}
          ,{<<"Media-Server">>, kz_term:to_binary(Node)}
          ,{<<"Method">>, <<"REGISTER">>}
          ,{<<"Orig-IP">>, NetworkIP}
          ,{<<"Orig-Port">>, NetworkPort}
          ,{<<"To">>, <<ToUser/binary, "@", ToHost/binary>>}
          | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    ReqResp = kz_amqp_worker:call(props:filter_undefined(Req)
                                 ,fun kapi_authn:publish_req/1
                                 ,fun kapi_authn:resp_v/1
                                 ),
    case ReqResp of
        {'error', _} -> Reg;
        {'ok', JObj} ->
            lager:debug("received authn information"),
            update_from_authn_response(Reg, JObj)
    end.

-spec update_from_authn_response(registration(), kz_json:object()) -> registration().
update_from_authn_response(#registration{realm=Realm
                                        ,username=Username
                                        }=Reg
                          ,JObj
                          ) ->
    CCVs = kz_json:get_json_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new()),
    AccountId = kz_json:get_value(<<"Account-ID">>, CCVs),
    AccountDb = kzs_util:format_account_db(AccountId),
    AuthorizingId = kz_json:get_value(<<"Authorizing-ID">>, CCVs),
    OwnerIdProp =
        case kz_json:get_value(<<"Owner-ID">>, CCVs) of
            'undefined' -> [];
            OwnerId -> [{'db', AccountDb, OwnerId}]
        end,
    CacheProps =
        [{'origin',
          [{'db', AccountDb, AuthorizingId}
          ,{'db', AccountDb, AccountId}
          | OwnerIdProp
          ]
         }
        ],
    kz_cache:store_local(?ECALLMGR_AUTH_CACHE
                        ,?CREDS_KEY(Realm, Username)
                        ,JObj
                        ,CacheProps
                        ),
    update_registration(
      augment_registration(Reg, JObj)
     ).

-spec update_registration(registration()) -> registration().
update_registration(#registration{account_db=AccountDb
                                 ,account_id=AccountId
                                 ,account_name=AccountName
                                 ,account_realm=AccountRealm
                                 ,authorizing_id=AuthorizingId
                                 ,authorizing_type=AuthorizingType
                                 ,id=Id
                                 ,owner_id=OwnerId
                                 ,presence_id=PresenceId
                                 ,register_overwrite_notify=RegisterOverwrite
                                 ,suppress_unregister=SuppressUnregister
                                 }=Reg
                   ) ->
    Props = [{#registration.account_db, AccountDb}
            ,{#registration.account_id, AccountId}
            ,{#registration.account_name, AccountName}
            ,{#registration.account_realm, AccountRealm}
            ,{#registration.authorizing_id, AuthorizingId}
            ,{#registration.authorizing_type, AuthorizingType}
            ,{#registration.owner_id, OwnerId}
            ,{#registration.presence_id, PresenceId}
            ,{#registration.register_overwrite_notify, RegisterOverwrite}
            ,{#registration.suppress_unregister, SuppressUnregister}
            ],
    _ = gen_server:cast(?SERVER, {'update_registration', Id, Props}),
    Reg.

-spec maybe_send_register_notice(registration()) -> registration().
maybe_send_register_notice(#registration{realm=Realm
                                        ,registrar_zone=Zone
                                        ,username=Username
                                        }=Reg
                          ) ->
    case should_handle_reg_notice(Zone) of
        'false' -> Reg;
        'true' ->
            lager:debug("sending register notice for ~s@~s", [Username, Realm]),
            _ = send_register_notice(Reg),
            Reg
    end.

-spec send_register_notice(registration()) -> 'ok'.
send_register_notice(Reg) ->
    Props = to_props(Reg)
        ++ kz_api:default_headers(?APP_NAME, ?APP_VERSION),
    kapi_notifications:publish_register(Props).

-spec maybe_send_deregister_notice(registration()) -> 'ok'.
maybe_send_deregister_notice(#registration{call_id=CallId
                                          ,realm=Realm
                                          ,suppress_unregister='true'
                                          ,username=Username
                                          }
                            ) ->
    kz_log:put_callid(CallId),
    lager:debug("registration ~s@~s expired", [Username, Realm]);
maybe_send_deregister_notice(#registration{call_id=CallId
                                          ,realm=Realm
                                          ,registrar_zone=Zone
                                          ,username=Username
                                          }=Reg
                            ) ->
    kz_log:put_callid(CallId),
    case should_handle_reg_notice(Zone) of
        'false' -> 'ok';
        'true' ->
            lager:debug("sending deregister notice for ~s@~s", [Username, Realm]),
            send_deregister_notice(Reg)
    end.

-spec send_deregister_notice(registration()) -> 'ok'.
send_deregister_notice(Reg) ->
    Props = to_props(Reg)
        ++ kz_api:default_headers(?APP_NAME, ?APP_VERSION),
    kz_amqp_worker:cast(Props, fun kapi_notifications:publish_deregister/1).

-spec maybe_registration_notify(registration()) -> registration().
maybe_registration_notify(#registration{register_overwrite_notify='false'}=Reg) -> Reg;
maybe_registration_notify(#registration{contact=Contact
                                       ,previous_contact=Contact
                                       ,register_overwrite_notify='true'
                                       }=Reg
                         ) ->
    Reg;
maybe_registration_notify(#registration{previous_contact='undefined'
                                       ,register_overwrite_notify='true'
                                       }=Reg
                         ) ->
    Reg;
maybe_registration_notify(#registration{register_overwrite_notify='true'}=Reg) ->
    _ = registration_notify(Reg),
    Reg.

-spec registration_notify(registration()) -> 'ok'.
registration_notify(#registration{contact=Contact
                                 ,previous_contact=PrevContact
                                 ,realm=Realm
                                 ,username=Username
                                 }) ->
    Props = props:filter_undefined(
              [{<<"Contact">>, Contact}
              ,{<<"Previous-Contact">>, PrevContact}
              ,{<<"Realm">>, Realm}
              ,{<<"Username">>, Username}
              | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
              ]),
    kapi_presence:publish_register_overwrite(Props).

-spec to_props(registration()) -> kz_term:proplist().
to_props(Reg) ->
    props:filter_undefined(
      [{<<"Account-DB">>, Reg#registration.account_db}
      ,{<<"Account-ID">>, Reg#registration.account_id}
      ,{<<"Account-Name">>, Reg#registration.account_name}
      ,{<<"Account-Realm">>, Reg#registration.account_realm}
      ,{<<"Authorizing-ID">>, Reg#registration.authorizing_id}
      ,{<<"Authorizing-Type">>, Reg#registration.authorizing_type}
      ,{<<"Bridge-RURI">>, Reg#registration.bridge_uri}
      ,{<<"Call-ID">>, Reg#registration.call_id}
      ,{<<"Contact">>, Reg#registration.contact}
      ,{<<"Event-Timestamp">>, Reg#registration.last_registration}
      ,{<<"Expires">>, Reg#registration.expires}
      ,{<<"First-Registration">>, Reg#registration.initial}
      ,{<<"From-Host">>, Reg#registration.from_host}
      ,{<<"From-User">>, Reg#registration.from_user}
      ,{<<"Initial-Registration">>, Reg#registration.initial_registration}
      ,{<<"Last-Registration">>, Reg#registration.last_registration}
      ,{<<"Network-IP">>, Reg#registration.network_ip}
      ,{<<"Network-Port">>, Reg#registration.network_port}
      ,{<<"Original-Contact">>, Reg#registration.original_contact}
      ,{<<"Owner-ID">>, Reg#registration.owner_id}
      ,{<<"Presence-ID">>, Reg#registration.presence_id}
      ,{<<"Previous-Contact">>, Reg#registration.previous_contact}
      ,{<<"Proxy-IP">>, Reg#registration.proxy_ip}
      ,{<<"Proxy-Path">>, Reg#registration.proxy}
      ,{<<"Proxy-Port">>, Reg#registration.proxy_port}
      ,{<<"Proxy-Protocol">>, Reg#registration.proxy_proto}
      ,{<<"Realm">>, Reg#registration.realm}
      ,{<<"Register-Overwrite-Notify">>, Reg#registration.register_overwrite_notify}
      ,{<<"Registrar-Hostname">>, Reg#registration.registrar_hostname}
      ,{<<"Registrar-Node">>, Reg#registration.registrar_node}
      ,{<<"Source-IP">>, Reg#registration.source_ip}
      ,{<<"Source-Port">>, Reg#registration.source_port}
      ,{<<"Suppress-Unregister-Notify">>, Reg#registration.suppress_unregister}
      ,{<<"To-Host">>, Reg#registration.to_host}
      ,{<<"To-User">>, Reg#registration.to_user}
      ,{<<"User-Agent">>, Reg#registration.user_agent}
      ,{<<"Username">>, Reg#registration.username}
      ,{<<"Endpoint-Token">>, Reg#registration.endpoint_token}
      ,{<<"Endpoint-Meta-ID">>, Reg#registration.meta_id}
      ,{<<"AOR">>, list_to_binary(["sip:", Reg#registration.username, "@", Reg#registration.realm])}
      ]
     ).

-spec should_handle_reg_notice(atom()) -> boolean().
should_handle_reg_notice(Zone) ->
    (kz_nodes:local_zone() =:= Zone
     andalso oldest_registrar('false'))
        orelse (no_registrar_in_reg_zone(Zone)
                andalso oldest_registrar('true')).

-spec no_registrar_in_reg_zone(atom()) -> boolean().
no_registrar_in_reg_zone(Zone) ->
    kz_nodes:whapp_oldest_node(?APP_NAME, Zone) =:= 'undefined'.

-spec oldest_registrar(boolean()) -> boolean().
oldest_registrar(Federated) ->
    kz_nodes:whapp_oldest_node(?APP_NAME, Federated) =:= node().

-spec get_fs_contact(kzd_freeswitch:data()) -> kz_term:ne_binary().
get_fs_contact(FSJObj) ->
    Contact = kzd_freeswitch:contact(FSJObj),
    [User, AfterAt] = binary:split(Contact, <<"@">>), % only one @ allowed
    <<User/binary, "@", (kz_http_util:urldecode(AfterAt))/binary>>.

-type ets_continuation() :: '$end_of_table' |
                            {registrations(), any()}.

-spec print_summary(ets_continuation()) -> 'ok'.
print_summary('$end_of_table') ->
    io:format("No registrations found!~n", []);
print_summary(Match) ->
    io:format("+-----------------------------------------------+------------------------+------------------------+----------------------------------+------+~n"),
    io:format("| User                                          | Contact                | Path                   | Call-ID                          |  Exp |~n"),
    io:format("+===============================================+========================+========================+==================================+======+~n"),
    print_summary(Match, 0).

-spec print_summary(ets_continuation(), non_neg_integer()) -> 'ok'.
print_summary('$end_of_table', Count) ->
    io:format("+-----------------------------------------------+------------------------+------------------------+----------------------------------+------+~n"),
    io:format("Found ~p registrations~n", [Count]);
print_summary({[#registration{call_id=CallId
                             ,contact=Contact
                             ,expires=Expires
                             ,last_registration=LastRegistration
                             ,proxy=Proxy
                             ,proxy_ip=ProxyIP
                             ,proxy_port=ProxyPort
                             ,proxy_proto=ProxyProto
                             ,realm=Realm
                             ,username=Username
                             }
               ]
              ,Continuation
              }
             ,Count
             ) ->
    User = <<Username/binary, "@", Realm/binary>>,
    Remaining = (LastRegistration + Expires) - kz_time:now_s(),
    Props = breakup_contact(Contact),
    Hostport = props:get_first_defined(['received', 'hostport'], Props),
    Path = proxy_path(Proxy, ProxyIP, ProxyPort, ProxyProto),
    io:format("| ~-45s | ~-22s | ~-22s | ~-32s | ~-4B |~n"
             ,[User, Hostport, Path, CallId, Remaining]
             ),
    print_summary(ets:select(Continuation), Count + 1).

-spec print_details(ets_continuation()) -> 'ok'.
print_details('$end_of_table') ->
    io:format("No registrations found!~n", []);
print_details(Match) ->
    print_details(Match, 0).

-spec print_details(ets_continuation(), non_neg_integer()) -> 'ok'.
print_details('$end_of_table', Count) ->
    io:format("~nFound ~p registrations~n", [Count]);
print_details({[#registration{}=Reg], Continuation}, Count) ->
    io:format("~n"),
    _ = [print_property(K, V, Reg)
         || {K, V} <- to_props(Reg)
        ],
    print_details(ets:select(Continuation), Count + 1).

print_property(<<"Expires">>=Key
              ,Value
              ,#registration{expires=Expires
                            ,last_registration=LastRegistration
                            }
              ) ->
    Remaining = (LastRegistration + Expires) - kz_time:now_s(),
    io:format("~-19s: ~b/~s~n", [Key, Remaining, kz_term:to_binary(Value)]);
print_property(Key, Value, _) ->
    io:format("~-19s: ~s~n", [Key, kz_term:to_binary(Value)]).

-type contact_param() :: {'uri', kz_term:ne_binary()} |
                         {'hostport', kz_term:ne_binary()} |
                         {'transport', kz_term:ne_binary()} |
                         {'fs_path', kz_term:ne_binary()} |
                         {'received', kz_term:ne_binary()}.
-type contact_params() :: [contact_param()].

-spec breakup_contact(kz_term:text()) -> contact_params().
breakup_contact(Contact) when is_binary(Contact) ->
    C = binary:replace(Contact, [<<$'>>, <<$<>>, <<$>>>, <<"sip:">>], <<>>, ['global']),
    [Uri|Parameters] = binary:split(C, <<";">>, ['global']),
    Hostport = get_contact_hostport(Uri),
    find_contact_parameters(Parameters, [{'uri', Uri}, {'hostport', Hostport}]);
breakup_contact(Contact) ->
    breakup_contact(kz_term:to_binary(Contact)).

-spec proxy_path(kz_term:api_binary(), kz_term:api_binary(), kz_term:api_integer(), kz_term:api_binary()) -> binary().
proxy_path(Proxy, IP, Port, 'undefined') -> proxy_path(Proxy, IP, Port, <<"udp">>);
proxy_path('undefined', 'undefined', 'undefined', _) -> <<>>;
proxy_path('undefined', 'undefined', Port, Proto) -> proxy_path('undefined', <<>>, Port, Proto);
proxy_path('undefined', IP, 'undefined', Proto) -> <<Proto/binary, ":", IP/binary>>;
proxy_path('undefined', IP, Port, Proto) -> <<Proto/binary, ":", IP/binary, ":", (kz_term:to_binary(Port))/binary>>;
proxy_path(Proxy, _, Port, Proto) ->
    Proxy1 = binary:replace(Proxy, <<"sip:">>, <<>>),
    case binary:match(Proxy1, <<":">>) of
        'nomatch' -> <<Proto/binary, ":", Proxy1/binary, ":", (kz_term:to_binary(Port))/binary>>;
        _ -> <<Proto/binary, ":", Proxy1/binary>>
    end.

-spec find_contact_parameters(kz_term:ne_binaries(), kz_term:proplist()) -> kz_term:proplist().
find_contact_parameters([], Props) -> Props;
find_contact_parameters([<<"transport=", Transport/binary>>|Parameters], Props) ->
    find_contact_parameters(Parameters, [{'transport', kz_term:to_lower_binary(Transport)}|Props]);
find_contact_parameters([<<"fs_path=", FsPath/binary>>|Parameters], Props) ->
    find_contact_parameters(Parameters, [{'fs_path', FsPath}|Props]);
find_contact_parameters([<<"received=", Received/binary>>|Parameters], Props) ->
    find_contact_parameters(Parameters, [{'received', Received}|Props]);
find_contact_parameters([_|Parameters], Props) ->
    find_contact_parameters(Parameters, Props).

-spec get_contact_hostport(kz_term:ne_binary()) -> kz_term:ne_binary().
get_contact_hostport(Uri) ->
    case binary:split(Uri, <<"@">>) of
        [_, Hostport] -> Hostport;
        _Else -> Uri
    end.

get_realm(JObj) ->
    kz_json:get_value(<<"Realm">>, JObj).

get_lower_realm(JObj) ->
    kz_term:to_lower_binary(get_realm(JObj)).
