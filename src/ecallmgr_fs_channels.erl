%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2025, 2600Hz
%%% @doc Track the FreeSWITCH channel information, and provide accessors
%%% @author James Aimonetti
%%% @author Karl Anderson
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_channels).
-behaviour(gen_listener).

-export([start_link/0]).
-export([sync/2]).
-export([summary/0
        ,summary/1
        ]).
-export([details/0
        ,details/1
        ]).
-export([show_all/0]).
-export([per_minute_accounts/0]).
-export([per_minute_channels/1]).
-export([flush_node/1]).
-export([new/1
        ,new_or_update/1
        ]).
-export([destroy/2]).
-export([update/3, updates/2, update_recording_status/3]).
-export([cleanup_old_channels/0, cleanup_old_channels/1
        ,max_channel_uptime/0
        ,set_max_channel_uptime/1, set_max_channel_uptime/2
        ]).
-export([match_presence/1]).
-export([count/0]).

-export([handle_query_auth_id/2]).
-export([handle_query_user_channels/2]).
-export([handle_query_endpoint_channels/2
        ,query_endpoint_channels/1, query_endpoint_channels/2, query_endpoint_channels/3
        ,count_endpoint_channels/1, count_endpoint_channels/2, count_endpoint_channels/3
        ]).
-export([handle_count/2
        ,count/1, count/2, count/3, count/4
        ]).
-export([handle_query_account_channels/2]).
-export([handle_query_channels/2]).
-export([handle_channel_status/2]).
-export([api_status/1]).

-export([channels/1, channels/2, channels/3, channels/4]).
-export([handle_channels/2]).

-export([has_channels_for_owner/1]).

-export([set_channels_update_default_strategy/0
        ,set_channels_update_strategy/1
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-include("ecallmgr.hrl").

-elvis([{elvis_style, no_debug_call, disable}]).

-define(SERVER, ?MODULE).

-define(RESPONDERS, [{{?MODULE, 'handle_query_auth_id'}
                     ,[{<<"channel">>, <<"query_auth_id_req">>}]
                     }
                    ,{{?MODULE, 'handle_query_user_channels'}
                     ,[{<<"channel">>, <<"query_user_channels_req">>}]
                     }
                    ,{{?MODULE, 'handle_query_account_channels'}
                     ,[{<<"channel">>, <<"query_account_channels_req">>}]
                     }
                    ,{{?MODULE, 'handle_query_channels'}
                     ,[{<<"channel">>, <<"query_channels_req">>}]
                     }
                    ,{{?MODULE, 'handle_channel_status'}
                     ,[{<<"channel">>, <<"channel_status_req">>}]
                     }
                    ,{{?MODULE, 'handle_query_endpoint_channels'}
                     ,[{<<"channel">>, <<"query_endpoint_channels_req">>}]
                     }
                    ,{{?MODULE, 'handle_count'}
                     ,[{<<"channel">>, <<"count_req">>}]
                     }
                    ,{{?MODULE, 'handle_channels'}
                     ,[{<<"channel">>, <<"channels_req">>}]
                     }
                    ]).
-define(BINDINGS, [{'call', [{'restrict_to', ['status_req', 'channels_req']}
                            ,'federate'
                            ]}
                  ]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-define(CALL_PARK_FEATURE, "*3").
-record(state, {max_channel_cleanup_ref :: reference()}).
-type state() :: #state{}.

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_listener:start_link({'local', ?SERVER}, ?MODULE, [{'responders', ?RESPONDERS}
                                                         ,{'bindings', ?BINDINGS}
                                                         ,{'queue_name', ?QUEUE_NAME}
                                                         ,{'queue_options', ?QUEUE_OPTIONS}
                                                         ,{'consume_options', ?CONSUME_OPTIONS}
                                                         ], []).

-spec sync(atom(), kz_term:ne_binaries()) -> 'ok'.
sync(Node, Channels) ->
    gen_server:cast(?SERVER, {'sync_channels', Node, Channels}).

-spec summary() -> 'ok'.
summary() ->
    MatchSpec = [{#channel{_ = '_'}
                 ,[]
                 ,['$_']
                 }],
    print_summary(ets:select(?CHANNELS_TBL, MatchSpec, 1)).

-spec summary(kz_term:text()) -> 'ok'.
summary(Node) when not is_atom(Node) ->
    summary(kz_term:to_atom(Node, 'true'));
summary(Node) ->
    MatchSpec = [{#channel{node='$1', _ = '_'}
                 ,[{'=:=', '$1', {'const', Node}}]
                 ,['$_']
                 }],
    print_summary(ets:select(?CHANNELS_TBL, MatchSpec, 1)).

-spec details() -> 'ok'.
details() ->
    MatchSpec = [{#channel{_ = '_'}
                 ,[]
                 ,['$_']
                 }],
    print_details(ets:select(?CHANNELS_TBL, MatchSpec, 1)).

-spec details(kz_term:text()) -> 'ok'.
details(UUID) when not is_binary(UUID) ->
    details(kz_term:to_binary(UUID));
details(UUID) ->
    MatchSpec = [{#channel{uuid='$1', _ = '_'}
                 ,[{'=:=', '$1', {'const', UUID}}]
                 ,['$_']
                 }],
    print_details(ets:select(?CHANNELS_TBL, MatchSpec, 1)).

-spec show_all() -> kz_json:objects().
show_all() ->
    ets:foldl(fun(Channel, Acc) ->
                      [ecallmgr_fs_channel:to_json(Channel) | Acc]
              end, [], ?CHANNELS_TBL).

-spec per_minute_accounts() -> kz_term:ne_binaries().
per_minute_accounts() ->
    MatchSpec = [{#channel{account_id = '$1'
                          ,account_billing = <<"per_minute">>
                          ,reseller_id = '$2'
                          ,reseller_billing = <<"per_minute">>
                          ,_ = '_'}
                 ,[{'andalso', {'=/=', '$1', 'undefined'}, {'=/=', '$2', 'undefined'}}]
                 ,['$$']
                 }
                ,{#channel{reseller_id = '$1', reseller_billing = <<"per_minute">>, _ = '_'}
                 ,[{'=/=', '$1', 'undefined'}]
                 ,['$$']
                 }
                ,{#channel{account_id = '$1', account_billing = <<"per_minute">>, _ = '_'}
                 ,[{'=/=', '$1', 'undefined'}]
                 ,['$$']
                 }
                ],
    lists:usort(lists:flatten(ets:select(?CHANNELS_TBL, MatchSpec))).

-spec per_minute_channels(kz_term:ne_binary()) -> [{atom(), kz_term:ne_binary()}].
per_minute_channels(AccountId) ->
    MatchSpec = [{#channel{node = '$1'
                          ,uuid = '$2'
                          ,reseller_id = AccountId
                          ,reseller_billing = <<"per_minute">>
                          ,_ = '_'
                          }
                 ,[]
                 ,[{{'$1', '$2'}}]
                 }
                ,{#channel{node = '$1'
                          ,uuid = '$2'
                          ,account_id = AccountId
                          ,account_billing = <<"per_minute">>
                          ,_ = '_'
                          }
                 ,[]
                 ,[{{'$1', '$2'}}]
                 }
                ],
    ets:select(?CHANNELS_TBL, MatchSpec).

-spec flush_node(string() | binary() | atom()) -> 'ok'.
flush_node(Node) ->
    gen_server:cast(?SERVER, {'flush_node', kz_term:to_atom(Node, 'true')}).

-spec new(channel()) -> 'ok'.
new(#channel{}=Channel) ->
    do_channel_insert('new_channel', Channel).

-spec new_or_update(channel()) -> 'ok'.
new_or_update(#channel{uuid=UUID}=Channel) ->
    'true' = do_channel_insert('new_or_update', Channel),
    lager:debug("channel ~s added/updated", [UUID]).

-spec destroy(kz_term:ne_binary(), atom()) -> 'ok'.
destroy(UUID, Node) ->
    do_channel_destroy(UUID, Node).

-spec update_recording_status(kz_term:ne_binary(), kz_term:ne_binary(), any()) -> 'ok'.
update_recording_status(UUID, MediaID, Status) ->
    do_update_recording_status(UUID, MediaID, Status).

-spec update(kz_term:ne_binary(), pos_integer(), any()) -> 'ok'.
update(UUID, Key, Value) ->
    do_update(UUID, [{Key, Value}]).

-spec updates(kz_term:ne_binary(), channel_updates()) -> 'ok'.
updates(UUID, Updates) ->
    do_update(UUID, remove_unneeded(Updates)).

-spec remove_unneeded(channel_updates()) -> channel_updates().
remove_unneeded(Updates) ->
    [KV || {Key, Value}=KV <- Updates,
           Key =/= #channel.uuid, % ets:update_element will fail if an update is also the key
           Value =/= 'undefined'  % only needed updates are passed to gen_server
    ].

-spec format_updates(kz_term:proplist()) -> kz_term:ne_binary().
format_updates(Updates) ->
    Fields = record_info('fields', 'channel'),
    Out = [format_update(lists:nth(Field - 1, Fields), V) || {Field, V} <- Updates],
    kz_binary:join(Out, <<",">>).

-spec format_update(kz_term:text(), term()) -> iodata().
format_update(Key, <<Value/binary>>) ->
    io_lib:format("~s=~p", [Key, binary_to_list(Value)]);
format_update(Key, Value) ->
    case kz_json:is_json_object(Value) of
        'true' ->  format_json_update(Key, Value);
        'false' -> io_lib:format("~s=~p", [Key, Value])
    end.

-spec format_json_update(kz_term:text(), kz_json:object()) -> iodata().
format_json_update(Key, Value) ->
    Out = [format_update(K, V) || {K, V} <- kz_json:to_proplist(Value)],
    io_lib:format("~s={~s}", [Key, kz_binary:join(Out, <<",">>)]).

-spec count() -> non_neg_integer().
count() -> ets:info(?CHANNELS_TBL, 'size').

-spec match_presence(kz_term:ne_binary()) -> kz_term:proplist_kv(kz_term:ne_binary(), atom()).
match_presence(PresenceId) ->
    MatchSpec = [{#channel{uuid = '$1'
                          ,presence_id = '$2'
                          ,node = '$3'
                          , _ = '_'
                          }
                 ,[{'=:=', '$2', {'const', PresenceId}}]
                 ,[{{'$1', '$3'}}]}
                ],
    ets:select(?CHANNELS_TBL, MatchSpec).

-spec handle_query_auth_id(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_query_auth_id(JObj, _Props) ->
    'true' = kapi_call:query_auth_id_req_v(JObj),
    AuthId = kz_json:get_ne_binary_value(<<"Auth-ID">>, JObj),
    Channels = case find_by_auth_id(AuthId) of
                   {'error', 'not_found'} -> [];
                   {'ok', C} -> C
               end,
    Resp = [{<<"Channels">>, Channels}
           ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    ServerId = kz_json:get_value(<<"Server-ID">>, JObj),
    kapi_call:publish_query_auth_id_resp(ServerId, Resp).

-spec handle_query_user_channels(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_query_user_channels(JObj, _Props) ->
    'true' = kapi_call:query_user_channels_req_v(JObj),
    UserChannels0 = case kz_json:get_value(<<"Realm">>, JObj) of
                        'undefined' -> [];
                        Realm ->
                            Usernames = kz_json:get_first_defined([<<"Username">>
                                                                  ,<<"Usernames">>
                                                                  ], JObj),
                            find_by_user_realm(Usernames, Realm)
                    end,
    UserChannels1 = case kz_json:get_value(<<"Authorizing-IDs">>, JObj) of
                        'undefined' -> [];
                        AuthIds -> find_by_authorizing_id(AuthIds)
                    end,
    UserChannels2 = lists:keymerge(1, UserChannels0, UserChannels1),
    handle_query_users_channels(JObj, UserChannels2).

-spec handle_query_users_channels(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_query_users_channels(JObj, Cs) ->
    Channels = [Channel || {_, Channel} <- Cs],
    send_user_query_resp(JObj, Channels).

-spec send_user_query_resp(kz_json:object(), kz_json:objects()) -> 'ok'.
send_user_query_resp(JObj, []) ->
    case kz_json:is_true(<<"Active-Only">>, JObj, 'true') of
        'true' -> lager:debug("no channels, not sending response");
        'false' ->
            lager:debug("no channels, sending empty response"),
            Resp = [{<<"Channels">>, []}
                   ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
                   | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],
            ServerId = kz_json:get_value(<<"Server-ID">>, JObj),
            lager:debug("sending back channel data to ~s", [ServerId]),
            kapi_call:publish_query_user_channels_resp(ServerId, Resp)
    end;
send_user_query_resp(JObj, Cs) ->
    Resp = [{<<"Channels">>, Cs}
           ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    ServerId = kz_json:get_value(<<"Server-ID">>, JObj),
    lager:debug("sending back channel data to ~s", [ServerId]),
    kapi_call:publish_query_user_channels_resp(ServerId, Resp).

-spec handle_query_account_channels(kz_json:object(), kz_term:ne_binary()) -> 'ok'.
handle_query_account_channels(JObj, _) ->
    AccountId = kz_json:get_value(<<"Account-ID">>, JObj),
    case find_account_channels(AccountId) of
        {'error', 'not_found'} -> send_account_query_resp(JObj, []);
        {'ok', Cs} -> send_account_query_resp(JObj, Cs)
    end.

-spec send_account_query_resp(kz_json:object(), kz_json:objects()) -> 'ok'.
send_account_query_resp(JObj, Cs) ->
    Resp = [{<<"Channels">>, Cs}
           ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    ServerId = kz_json:get_value(<<"Server-ID">>, JObj),
    lager:debug("sending back channel data to ~s", [ServerId]),
    kapi_call:publish_query_account_channels_resp(ServerId, Resp).

-spec handle_query_channels(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_query_channels(JObj, _Props) ->
    'true' = kapi_call:query_channels_req_v(JObj),
    Fields = kz_json:get_value(<<"Fields">>, JObj, []),
    CallId = kz_json:get_value(<<"Call-ID">>, JObj),
    Channels = query_channels(Fields, CallId),
    case kz_term:is_empty(Channels) and
        kz_json:is_true(<<"Active-Only">>, JObj, 'false')
    of
        'true' ->
            lager:debug("no channels found, not sending query_channels resp due to active-only=true");
        'false' ->
            lager:debug("found ~B channels, sending reply", [length(kz_json:get_keys(Channels))]),
            Resp = [{<<"Channels">>, Channels}
                   ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
                   | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],
            kapi_call:publish_query_channels_resp(kz_json:get_value(<<"Server-ID">>, JObj), Resp)
    end.

-spec handle_channel_status(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_channel_status(JObj, _Props) ->
    'true' = kapi_call:channel_status_req_v(JObj),
    _ = kz_log:put_callid(JObj),
    CallId = kz_api:call_id(JObj),
    ChannelRecord = kz_json:is_true(<<"Channel-Record">>, JObj),
    lager:debug("channel status request received"),
    case api_status(CallId, ChannelRecord) of
        {'error', _Reason} ->
            maybe_send_empty_channel_resp(CallId, JObj);
        {'ok', Status} ->
            Resp = [{<<"Msg-ID">>, kz_api:msg_id(JObj)} | Status],
            lager:debug("sending back channel data to ~s", [kz_api:server_id(JObj)]),
            kapi_call:publish_channel_status_resp(kz_api:server_id(JObj), Resp)
    end.

-type api_status_node_info() :: {kz_term:ne_binary(), kz_term:ne_binary()}.

-spec api_status(kz_term:ne_binary()) ->
          {'ok', kz_term:proplist()} |
          {'error', 'not_found'}.
api_status(CallId) ->
    api_status(CallId, 'false').

-spec api_status(kz_term:ne_binary(), boolean()) ->
          {'ok', kz_term:proplist()} |
          {'error', 'not_found'}.
api_status(CallId, ChannelRecord) ->
    case ecallmgr_fs_channel:fetch(CallId, 'api') of
        {'error', _} = Error -> Error;
        {'ok', Channel} -> api_status_return(CallId, ChannelRecord, Channel)
    end.

-spec api_status_return(kz_term:ne_binary(), boolean(), kz_json:object()) -> {'ok', kz_term:proplist()}.
api_status_return(CallId, 'true', Channel) ->
    api_status_log_node(Channel),
    Resp = [{<<"Call-ID">>, CallId}
           ,{<<"Status">>, <<"active">>}
           ,{<<"Channel-Record">>, Channel}
           ],
    {'ok', Resp ++ kz_api:default_headers(?APP_NAME, ?APP_VERSION)};
api_status_return(CallId, 'false', Channel) ->
    {Node, Hostname} = api_status_node(Channel),
    lager:debug("channel is on ~s", [Hostname]),
    Profile = kz_json:get_binary_value(<<"Profile">>, Channel),
    Resp = props:filter_undefined(
             [{<<"Call-ID">>, CallId}
             ,{<<"Status">>, <<"active">>}
             ,{<<"Switch-Hostname">>, Hostname}
             ,{<<"Switch-Nodename">>, kz_term:to_binary(Node)}
             ,{<<"Switch-URL">>, kz_json:get_ne_binary_value(<<"Switch-URL">>, Channel, ecallmgr_fs_nodes:sip_url(Node, Profile))}
             ,{<<"Realm">>, kz_json:get_value(<<"Realm">>, Channel)}
             ,{<<"Username">>, kz_json:get_value(<<"Username">>, Channel)}
             ,{<<"Custom-Channel-Vars">>, kz_json:from_list(ecallmgr_fs_channel:channel_ccvs(Channel))}
             ,{<<"Custom-Application-Vars">>, kz_json:from_list(ecallmgr_fs_channel:channel_cavs(Channel))}
             ,{<<"Custom-SIP-Headers">>, kz_json:from_list(ecallmgr_fs_channel:channel_cshs(Channel))}
             ,{<<"Custom-AUTH-Headers">>, kz_json:from_list(ecallmgr_fs_channel:channel_cahs(Channel))}
             | [{Key, kz_json:get_ne_value(Key, Channel)} || Key <- kapi_call:channel_status_extended_headers()]
             ]
            ),
    {'ok', Resp ++ kz_api:default_headers(?APP_NAME, ?APP_VERSION)}.

-spec api_status_node(kz_json:object()) -> api_status_node_info().
api_status_node(Channel) ->
    Node = kz_json:get_binary_value(<<"Media-Node">>, Channel),
    Hostname = case binary:split(Node, <<"@">>) of
                   [_, Host] -> Host;
                   Other -> Other
               end,
    {Node, Hostname}.

-spec api_status_log_node(kz_json:object() | api_status_node_info()) -> 'ok'.
api_status_log_node({_Node, Hostname}) ->
    lager:debug("channel is on ~s", [Hostname]);
api_status_log_node(Channel) ->
    api_status_log_node(api_status_node(Channel)).

-spec maybe_send_empty_channel_resp(kz_term:ne_binary(), kz_json:object()) -> 'ok'.
maybe_send_empty_channel_resp(CallId, JObj) ->
    case kz_json:is_true(<<"Active-Only">>, JObj) of
        'true' -> 'ok';
        'false' -> send_empty_channel_resp(CallId, JObj)
    end.

-spec send_empty_channel_resp(kz_term:ne_binary(), kz_json:object()) -> 'ok'.
send_empty_channel_resp(CallId, JObj) ->
    Resp = [{<<"Call-ID">>, CallId}
           ,{<<"Status">>, <<"terminated">>}
           ,{<<"Error-Msg">>, <<"no node found with channel">>}
           ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    lager:debug("sending back empty channel data to ~s", [kz_api:server_id(JObj)]),
    kapi_call:publish_channel_status_resp(kz_api:server_id(JObj), Resp).

-spec handle_query_endpoint_channels(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_query_endpoint_channels(JObj, _Props) ->
    'true' = kapi_call:query_endpoint_channels_req_v(JObj),
    UUIDs = query_endpoint_channels(JObj),
    CountOnly = kz_json:is_true(<<"Count-Only">>, JObj),
    Resp = [query_endpoint_channels_reply(CountOnly, UUIDs)
           ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    ServerId = kz_api:server_id(JObj),
    lager:debug("sending back endpoint query (~B) result to ~s", [length(UUIDs), ServerId]),
    kapi_call:publish_query_endpoint_channels_resp(ServerId, Resp).

query_endpoint_channels_reply('true', UUIDs) -> {<<"Count">>, length(UUIDs)};
query_endpoint_channels_reply('false', UUIDs) -> {<<"Channels">>, UUIDs}.


-spec count_endpoint_channels(kz_json:object()) -> integer().
count_endpoint_channels(JObj) ->
    length(query_endpoint_channels(JObj)).

-spec count_endpoint_channels(kz_term:ne_binary(), kz_term:ne_binary()) -> integer().
count_endpoint_channels(AccountId, EndpointId) ->
    length(query_endpoint_channels(AccountId, EndpointId)).

-spec count_endpoint_channels(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:api_ne_binary()) -> integer().
count_endpoint_channels(AccountId, EndpointId, Direction) ->
    length(query_endpoint_channels(AccountId, EndpointId, Direction)).

-spec query_endpoint_channels(kz_json:object()) -> kz_term:ne_binaries().
query_endpoint_channels(JObj) ->
    AccountId = kz_json:get_ne_binary_value(<<"Account-ID">>, JObj),
    EndpointId = kz_json:get_ne_binary_value(<<"Endpoint-ID">>, JObj),
    Direction = kz_json:get_ne_binary_value(<<"Direction">>, JObj),
    query_endpoint_channels(AccountId, EndpointId, Direction).

-spec query_endpoint_channels(kz_term:ne_binary(), kz_term:ne_binary()) -> kz_term:ne_binaries().
query_endpoint_channels(AccountId, EndpointId) ->
    query_endpoint_channels(AccountId, EndpointId, 'undefined').

-spec query_endpoint_channels(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:api_ne_binary()) -> kz_term:ne_binaries().
query_endpoint_channels(AccountId, EndpointId, Direction) ->
    MatchSpec = query_endpoint_channels_match_spec(AccountId, EndpointId, Direction),
    ets:select(?CHANNELS_TBL, MatchSpec).

query_endpoint_channels_match_spec(AccountId, EndpointId, 'undefined') ->
    [{#channel{uuid = '$1', account_id = '$2', authorizing_id = '$3', owner_id = '$4', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'orelse',
         {'=:=', '$3', {'const', EndpointId}}
        ,{'=:=', '$4', {'const', EndpointId}}
        }
       }
      ]
     ,['$1']}
    ];
query_endpoint_channels_match_spec(AccountId, EndpointId, Direction) ->
    [{#channel{uuid = '$1', account_id = '$2', authorizing_id = '$3', owner_id = '$4', direction = '$5', _ = '_'}
     ,[{'andalso',
        {'andalso',
         {'=:=', '$2', {'const', AccountId}},
         {'orelse',
          {'=:=', '$3', {'const', EndpointId}}
         ,{'=:=', '$4', {'const', EndpointId}}
         }
        }
       ,{'=:=', '$5', {'const', Direction}}
       }
      ]
     ,['$1']}
    ].

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?MODULE),
    process_flag('trap_exit', 'true'),
    lager:debug("starting new fs channels"),
    _ = ets:new(?CHANNELS_TBL, ['set'
                               ,'public'
                               ,'named_table'
                               ,{'keypos', #channel.uuid}
                               ,{'read_concurrency', 'true'}
                               ,{'write_concurrency', 'true'}
                               ]),
    pg:join({kz_config:zone(), 'channel_cache'}, self()),
    {'ok', #state{max_channel_cleanup_ref=start_cleanup_ref()}}.

-define(CLEANUP_TIMEOUT
       ,kapps_config:get_integer(?APP_NAME, <<"max_channel_cleanup_timeout_ms">>, ?MILLISECONDS_IN_MINUTE)
       ).

-spec start_cleanup_ref() -> reference().
start_cleanup_ref() ->
    erlang:start_timer(?CLEANUP_TIMEOUT, self(), 'ok').

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call({'new_channel', #channel{uuid=UUID}=Channel}, _, State) ->
    case ets:insert_new(?CHANNELS_TBL, Channel) of
        'true'->
            lager:debug("channel ~s added", [UUID]),
            {'reply', 'ok', State};
        'false' ->
            lager:debug("channel ~s already exists", [UUID]),
            {'reply', {'error', 'channel_exists'}, State}
    end;
handle_call({'new_or_update', #channel{}=Channel}, _, State) ->
    Result = ets:insert(?CHANNELS_TBL, Channel),
    {'reply', Result, State};
handle_call({'count', {AccountId, OwnerId, DeviceId, Direction}}, From, State) ->
    _ = kz_process:spawn(fun() -> gen_server:reply(From, count(AccountId, OwnerId, DeviceId, Direction)) end),
    {'noreply', State};
handle_call({'count', Args}, From, State) when is_map(Args) ->
    _ = kz_process:spawn(fun() -> gen_server:reply(From, count(Args)) end),
    {'noreply', State};
handle_call({'channels', {AccountId, OwnerId, DeviceId, Direction}}, From, State) ->
    _ = kz_process:spawn(fun() -> gen_server:reply(From, channels(AccountId, OwnerId, DeviceId, Direction)) end),
    {'noreply', State};
handle_call({'channels', Args}, From, State) when is_map(Args) ->
    _ = kz_process:spawn(fun() -> gen_server:reply(From, channels(Args)) end),
    {'noreply', State};
handle_call(_Args, _From, State) ->
    lager:error("unhandled call => ~p => ~p", [_Args, _From]),
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
maybe_log_updates('false', UUID, _Updates) ->
    lager:debug("channel ~s not found, no property updates", [UUID]);
maybe_log_updates('true', UUID, Updates) ->
    lager:debug("updating channel ~s properties: ~s", [UUID, format_updates(Updates)]).

-spec handle_cast(any(), state()) -> {'noreply', state()}.
handle_cast({'channel_updates', UUID, Updates}, State) ->
    WasUpdated = ets:update_element(?CHANNELS_TBL, UUID, Updates),
    maybe_log_updates(WasUpdated, UUID, Updates),
    {'noreply', State};
handle_cast({'channel_recording_update', UUID, RecordingID, RecordingEvent}, State) ->
    set_channel_recording_status(UUID, RecordingID, RecordingEvent),
    {'noreply', State};
handle_cast({'destroy_channel', UUID, Node}, State) ->
    MatchSpec = channel_match_for_delete(UUID, Node),
    N = ets:select_delete(?CHANNELS_TBL, MatchSpec),
    lager:debug("removed ~p channel(s) with call-id ~s on ~s", [N, UUID, Node]),
    {'noreply', State, 'hibernate'};

handle_cast({'sync_channels', Node, Channels}, State) ->
    lager:debug("ensuring channel cache is in sync with ~s", [Node]),
    MatchSpec = [{#channel{uuid = '$1', node = '$2', _ = '_'}
                 ,[{'=:=', '$2', {'const', Node}}]
                 ,['$1']}
                ],
    CachedChannels = sets:from_list(ets:select(?CHANNELS_TBL, MatchSpec)),
    SyncChannels = sets:from_list(Channels),
    Remove = sets:subtract(CachedChannels, SyncChannels),
    Add = sets:subtract(SyncChannels, CachedChannels),
    _ = [delete_and_maybe_disconnect(Node, UUID, ets:lookup(?CHANNELS_TBL, UUID))
         || UUID <- sets:to_list(Remove)
        ],
    _ = [begin
             lager:debug("trying to add channel ~s to cache during sync with ~s", [UUID, Node]),
             case ecallmgr_fs_channel:renew(Node, UUID) of
                 {'error', _R} -> lager:warning("failed to sync channel ~s: ~p", [UUID, _R]);
                 {'ok', C} ->
                     lager:debug("added channel ~s to cache during sync with ~s", [UUID, Node]),
                     ets:insert(?CHANNELS_TBL, C),
                     PublishReconect = kapps_config:get_boolean(?APP_NAME, <<"publish_channel_reconnect">>, 'false'),
                     handle_channel_reconnected(C, PublishReconect)
             end
         end
         || UUID <- sets:to_list(Add)
        ],
    {'noreply', State, 'hibernate'};
handle_cast({'flush_node', Node}, State) ->
    lager:debug("flushing all channels in cache associated to node ~s", [Node]),

    LocalChannelsMS = [{#channel{node = '$1'
                                ,handling_locally='true'
                                ,_ = '_'
                                }
                       ,[{'=:=', '$1', {'const', Node}}]
                       ,['$_']}
                      ],
    case ets:select(?CHANNELS_TBL, LocalChannelsMS) of
        [] ->
            lager:debug("no locally handled channels");
        LocalChannels ->
            _P = kz_process:spawn(fun handle_channels_disconnected/1, [LocalChannels]),
            lager:debug("sending channel disconnects for local channels: ~p", [LocalChannels])
    end,

    MatchSpec = [{#channel{node = '$1', _ = '_'}
                 ,[{'=:=', '$1', {'const', Node}}]
                 ,['true']}
                ],
    ets:select_delete(?CHANNELS_TBL, MatchSpec),
    {'noreply', State};
handle_cast({'gen_listener',{'created_queue', _QueueName}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};
handle_cast(_Req, State) ->
    lager:debug("unhandled cast: ~p", [_Req]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'timeout', Ref, _Msg}, #state{max_channel_cleanup_ref=Ref}=State) ->
    maybe_cleanup_old_channels(),
    {'noreply', State#state{max_channel_cleanup_ref=start_cleanup_ref()}};
handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> gen_listener:handle_event_return().
handle_event(_JObj, #state{}) ->
    {'reply', []}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, #state{}) ->
    ets:delete(?CHANNELS_TBL),
    lager:info("fs channels terminating: ~p", [_Reason]).

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
-spec find_by_auth_id(kz_term:ne_binary()) ->
          {'ok', kz_json:objects()} |
          {'error', 'not_found'}.
find_by_auth_id(AuthorizingId) ->
    MatchSpec = [{#channel{authorizing_id = '$1', _ = '_'}
                 ,[{'=:=', '$1', {'const', AuthorizingId}}]
                 ,['$_']}
                ],
    case ets:select(?CHANNELS_TBL, MatchSpec) of
        [] -> {'error', 'not_found'};
        Channels -> {'ok', [ecallmgr_fs_channel:to_json(Channel)
                            || Channel <- Channels
                           ]}
    end.

-spec has_channels_for_owner(kz_term:ne_binary()) -> boolean().
has_channels_for_owner(OwnerId) ->
    MatchSpec = [{#channel{owner_id = '$1'
                          ,_ = '_'
                          }
                 ,[]
                 ,[{'=:=', '$1', {'const', OwnerId}}]
                 }
                ],
    Count = ets:select_count(?CHANNELS_TBL, MatchSpec),
    lager:info("found ~p channels", [Count]),
    Count > 0.

-spec find_by_authorizing_id(kz_term:ne_binaries()) -> [] | kz_term:proplist().
find_by_authorizing_id(AuthIds) ->
    find_by_authorizing_id(AuthIds, []).

-spec find_by_authorizing_id(kz_term:ne_binaries(), kz_term:proplist()) -> [] | kz_term:proplist().
find_by_authorizing_id([], Acc) -> Acc;
find_by_authorizing_id([AuthId|AuthIds], Acc) ->
    Pattern = #channel{authorizing_id=AuthId
                      ,_='_'},
    case ets:match_object(?CHANNELS_TBL, Pattern) of
        [] -> find_by_authorizing_id(AuthIds, Acc);
        Channels ->
            Cs = [{Channel#channel.uuid, ecallmgr_fs_channel:to_json(Channel)}
                  || Channel <- Channels
                 ],
            find_by_authorizing_id(AuthIds, lists:keymerge(1, Acc, Cs))
    end.

-spec find_by_user_realm(kz_term:api_binary() | kz_term:ne_binaries(), kz_term:ne_binary()) -> [] | kz_term:proplist().
find_by_user_realm('undefined', Realm) ->
    lager:debug("search channels in realm ~s", [Realm]),
    Pattern = #channel{realm=kz_term:to_lower_binary(Realm)
                      ,_='_'},
    case ets:match_object(?CHANNELS_TBL, Pattern) of
        [] -> [];
        Channels ->
            [{Channel#channel.uuid, ecallmgr_fs_channel:to_json(Channel)}
             || Channel <- Channels
            ]
    end;
%% this only works for direct park, valet usage on parking will not work for this and kamailio query for shortcut will fail
find_by_user_realm(<<?CALL_PARK_FEATURE, _/binary>>=Username, Realm) ->
    lager:debug("search channels for call park feature in realm ~s", [Realm]),
    Pattern = #channel{destination=Username
                      ,realm=kz_term:to_lower_binary(Realm)
                      ,other_leg='undefined'
                      ,_='_'},
    case ets:match_object(?CHANNELS_TBL, Pattern) of
        [] -> [];
        Channels ->
            [{Channel#channel.uuid, ecallmgr_fs_channel:to_json(Channel)}
             || Channel <- Channels
            ]
    end;
find_by_user_realm(Usernames, Realm) when is_list(Usernames) ->
    lager:debug("search channels for users ~s in realm ~s", [kz_binary:join(Usernames), Realm]),
    ETSUsernames = build_matchspec_ors(Usernames),
    MatchSpec = [{#channel{username='$1'
                          ,realm=kz_term:to_lower_binary(Realm)
                          ,_ = '_'}
                 ,[ETSUsernames]
                 ,['$_']
                 }],
    case ets:select(?CHANNELS_TBL, MatchSpec) of
        [] -> [];
        Channels ->
            [{Channel#channel.uuid, ecallmgr_fs_channel:to_json(Channel)}
             || Channel <- Channels
            ]
    end;
find_by_user_realm(Username, Realm) ->
    lager:debug("search channels for user ~s in realm ~s", [Username, Realm]),
    Pattern = #channel{username=Username
                      ,realm=kz_term:to_lower_binary(Realm)
                      ,_='_'},
    case ets:match_object(?CHANNELS_TBL, Pattern) of
        [] -> [];
        Channels ->
            [{Channel#channel.uuid, ecallmgr_fs_channel:to_json(Channel)}
             || Channel <- Channels
            ]
    end.

-spec find_account_channels(kz_term:ne_binary()) ->
          {'ok', kz_json:objects()} |
          {'error', 'not_found'}.
find_account_channels(<<"all">>) ->
    lager:debug("search channels for all accounts"),
    case ets:match_object(?CHANNELS_TBL, #channel{_='_'}) of
        [] -> {'error', 'not_found'};
        Channels ->
            {'ok', [ecallmgr_fs_channel:to_json(Channel)
                    || Channel <- Channels
                   ]}
    end;
find_account_channels(AccountId) ->
    lager:debug("search channels for account ~s", [AccountId]),
    case ets:match_object(?CHANNELS_TBL, #channel{account_id=AccountId, _='_'}) of
        [] -> {'error', 'not_found'};
        Channels ->
            {'ok', [ecallmgr_fs_channel:to_json(Channel)
                    || Channel <- Channels
                   ]}
    end.

-spec build_matchspec_ors(kz_term:ne_binaries()) -> tuple() | 'false'.
build_matchspec_ors(Usernames) ->
    lists:foldl(fun build_matchspec_ors_fold/2
               ,'false'
               ,Usernames
               ).

-spec build_matchspec_ors_fold(kz_term:ne_binary(), tuple() | 'false') -> tuple().
build_matchspec_ors_fold(Username, Acc) ->
    {'or', {'=:=', '$1', Username}, Acc}.

log_fields(Fields)
  when is_list(Fields) -> kz_binary:join(Fields);
log_fields(Field) -> Field.

-spec query_channels(kz_term:ne_binaries(), kz_term:api_binary()) -> kz_json:object().
query_channels(Fields, 'undefined') ->
    lager:debug("query all channels returning fields : ~s", [log_fields(Fields)]),
    query_channels(ets:match_object(?CHANNELS_TBL, #channel{_='_'}, 1)
                  ,Fields
                  ,kz_json:new()
                  );
query_channels(Fields, CallId) ->
    lager:debug("query channel ~s returning fields : ~s", [CallId, log_fields(Fields)]),
    query_channels(ets:match_object(?CHANNELS_TBL, #channel{uuid=CallId, _='_'}, 1)
                  ,Fields
                  ,kz_json:new()
                  ).

-spec query_channels({[channel()], ets:continuation()} | '$end_of_table', kz_term:ne_binary() | kz_term:ne_binaries(), kz_json:object()) ->
          kz_json:object().
query_channels('$end_of_table', _, Channels) -> Channels;
query_channels({[#channel{uuid=CallId}=Channel], Continuation}
              ,<<"all">>
              ,Channels
              ) ->
    JObj = ecallmgr_fs_channel:to_api_json(Channel),
    query_channels(ets:match_object(Continuation)
                  ,<<"all">>
                  ,kz_json:set_value(CallId, JObj, Channels)
                  );
query_channels({[#channel{uuid=CallId}=Channel], Continuation}
              ,Fields
              ,Channels
              ) ->
    ChannelProps = ecallmgr_fs_channel:to_api_props(Channel),
    JObj = kz_json:from_list(
             [{Field, props:get_value(Field, ChannelProps)}
              || Field <- Fields
             ]),
    query_channels(ets:match_object(Continuation)
                  ,Fields
                  ,kz_json:set_value(CallId, JObj, Channels)
                  ).

-define(SUMMARY_HEADER, "| ~-50s | ~-40s | ~-9s | ~-15s | ~-32s |~n").

print_summary('$end_of_table') ->
    io:format("No channels found!~n", []);
print_summary(Match) ->
    io:format("+----------------------------------------------------+------------------------------------------+-----------+-----------------+----------------------------------+~n"),
    io:format(?SUMMARY_HEADER
             ,[ <<"UUID">>, <<"Node">>, <<"Direction">>, <<"Destination">>, <<"Account-ID">>]
             ),
    io:format("+====================================================+==========================================+===========+=================+==================================+~n"),
    print_summary(Match, 0).

print_summary('$end_of_table', Count) ->
    io:format("+----------------------------------------------------+------------------------------------------+-----------+-----------------+----------------------------------+~n"),
    io:format("Found ~p channels~n", [Count]);
print_summary({[#channel{uuid=UUID
                        ,node=Node
                        ,direction=Direction
                        ,destination=Destination
                        ,account_id=AccountId
                        }]
              ,Continuation
              }
             ,Count
             ) ->
    io:format(?SUMMARY_HEADER
             ,[UUID, Node, Direction, Destination, AccountId]
             ),
    print_summary(ets:select(Continuation), Count + 1).

print_details('$end_of_table') ->
    io:format("No channels found!~n", []);
print_details(Match) ->
    print_details(Match, 0).

print_details('$end_of_table', Count) ->
    io:format("~nFound ~p channels~n", [Count]);
print_details({[#channel{}=Channel]
              ,Continuation
              }
             ,Count
             ) ->
    io:format("~n"),
    _ = [io:format("~-19s: ~s~n", [K, kz_term:to_binary(V)])
         || {K, V} <- ecallmgr_fs_channel:to_props(Channel),
            not kz_json:is_json_object(V)
        ],
    print_details(ets:select(Continuation), Count + 1).

-spec handle_channel_reconnected(channel(), boolean()) -> 'ok'.
handle_channel_reconnected(#channel{handling_locally='true'
                                   ,uuid=_UUID
                                   }=Channel
                          ,'true'
                          ) ->
    lager:debug("channel ~s connected, publishing update", [_UUID]),
    publish_channel_connection_event(Channel, [{<<"Event-Name">>, <<"CHANNEL_CONNECTED">>}]);
handle_channel_reconnected(_Channel, _ShouldPublish) ->
    'ok'.

-spec handle_channels_disconnected(channels()) -> 'ok'.
handle_channels_disconnected(LocalChannels) ->
    _ = [catch handle_channel_disconnected(LocalChannel) || LocalChannel <- LocalChannels],
    'ok'.

-spec handle_channel_disconnected(channel()) -> 'ok'.
handle_channel_disconnected(Channel) ->
    publish_channel_connection_event(Channel, [{<<"Event-Name">>, <<"CHANNEL_DISCONNECTED">>}]).

-spec publish_channel_connection_event(channel(), kz_term:proplist()) -> 'ok'.
publish_channel_connection_event(#channel{uuid=UUID
                                         ,direction=Direction
                                         ,node=Node
                                         ,presence_id=PresenceId
                                         ,answered=IsAnswered
                                         ,from=From
                                         ,to=To
                                         }=Channel
                                ,ChannelSpecific
                                ) ->
    Event = [{<<"Timestamp">>, kz_time:now_s()}
            ,{<<"Call-ID">>, UUID}
            ,{<<"Call-Direction">>, Direction}
            ,{<<"Media-Server">>, Node}
            ,{<<"Custom-Channel-Vars">>, connection_ccvs(Channel)}
            ,{<<"Custom-Application-Vars">>, connection_cavs(Channel)}
            ,{<<"To">>, To}
            ,{<<"From">>, From}
            ,{<<"Presence-ID">>, PresenceId}
            ,{<<"Channel-Call-State">>, channel_call_state(IsAnswered)}
            | kz_api:default_headers(?APP_NAME, ?APP_VERSION) ++ ChannelSpecific
            ],
    _ = kz_amqp_worker:cast(Event, fun kapi_call:publish_event/1),
    lager:debug("published channel connection event (~s) for ~s", [kz_api:event_name(Event), UUID]).

-spec channel_call_state(boolean()) -> kz_term:api_binary().
channel_call_state('true') ->
    <<"ANSWERED">>;
channel_call_state('false') ->
    'undefined'.

-spec connection_ccvs(channel()) -> kz_term:api_object().
connection_ccvs(#channel{ccvs=CCVs}) -> CCVs.

-spec connection_cavs(channel()) -> kz_term:api_object().
connection_cavs(#channel{cavs=CAVs}) -> CAVs.

-define(MAX_CHANNEL_UPTIME_KEY, <<"max_channel_uptime_s">>).

-spec max_channel_uptime() -> non_neg_integer().
max_channel_uptime() ->
    kapps_config:get_integer(?APP_NAME, ?MAX_CHANNEL_UPTIME_KEY, 0).

-spec set_max_channel_uptime(non_neg_integer()) ->
          {'ok', kz_json:object()} |
          kz_datamgr:data_error().
set_max_channel_uptime(MaxAge) ->
    set_max_channel_uptime(MaxAge, 'true').

-spec set_max_channel_uptime(non_neg_integer(), boolean()) ->
          {'ok', kz_json:object()} |
          kz_datamgr:data_error().
set_max_channel_uptime(MaxAge, 'true') ->
    kapps_config:set_default(?APP_NAME, ?MAX_CHANNEL_UPTIME_KEY, kz_term:to_integer(MaxAge));
set_max_channel_uptime(MaxAge, 'false') ->
    kapps_config:set(?APP_NAME, ?MAX_CHANNEL_UPTIME_KEY, kz_term:to_integer(MaxAge)).

-spec maybe_cleanup_old_channels() -> 'ok'.
maybe_cleanup_old_channels() ->
    case max_channel_uptime() of
        N when N =< 0 -> 'ok';
        MaxAge ->
            _P = kz_process:spawn(fun cleanup_old_channels/1, [MaxAge]),
            'ok'
    end.

-spec cleanup_old_channels() -> non_neg_integer().
cleanup_old_channels() ->
    cleanup_old_channels(max_channel_uptime()).

-spec cleanup_old_channels(non_neg_integer()) -> non_neg_integer().
cleanup_old_channels(MaxAge) ->
    NoOlderThan = kz_time:now_s() - MaxAge,

    MatchSpec = [{#channel{uuid='$1'
                          ,node='$2'
                          ,timestamp='$3'
                          ,handling_locally='true'
                          ,_ = '_'
                          }
                 ,[{'<', '$3', NoOlderThan}]
                 ,[['$1', '$2', '$3']]
                 }],
    case ets:select(?CHANNELS_TBL, MatchSpec) of
        [] -> 0;
        OldChannels ->
            N = length(OldChannels),
            lager:debug("~p channels over ~p seconds old", [N, MaxAge]),
            hangup_old_channels(OldChannels),
            N
    end.

-type old_channel() :: [kz_term:ne_binary() | atom() | kz_time:gregorian_seconds()].
-type old_channels() :: [old_channel(),...].

-spec hangup_old_channels(old_channels()) -> 'ok'.
hangup_old_channels(OldChannels) ->
    lists:foreach(fun hangup_old_channel/1, OldChannels).

-spec hangup_old_channel(old_channel()) -> 'ok'.
hangup_old_channel([UUID, Node, Started]) ->
    lager:debug("killing channel ~s on ~s, started ~s"
               ,[UUID, Node, kz_time:pretty_print_datetime(Started)]),
    freeswitch:api(Node, 'uuid_kill', UUID).

-spec delete_and_maybe_disconnect(atom(), kz_term:ne_binary(), [channel()]) -> 'ok' | 'true'.
delete_and_maybe_disconnect(Node, UUID, [#channel{handling_locally='true'}=Channel]) ->
    lager:debug("emitting channel disconnect ~s during sync with ~s", [UUID, Node]),
    handle_channel_disconnected(Channel),
    ets:delete(?CHANNELS_TBL, UUID);
delete_and_maybe_disconnect(Node, UUID, [_Channel]) ->
    lager:debug("removed channel ~s from cache during sync with ~s", [UUID, Node]),
    ets:delete(?CHANNELS_TBL, UUID);
delete_and_maybe_disconnect(Node, UUID, []) ->
    lager:debug("channel ~s not found during sync delete with ~s", [UUID, Node]).

do_update(UUID, Updates) ->
    Strategy = persistent_term:get('channels_update_strategy', 'server'),
    do_update(Strategy, UUID, Updates).

do_update('concurrency', UUID, Updates) ->
    WasUpdated = ets:update_element(?CHANNELS_TBL, UUID, Updates),
    maybe_log_updates(WasUpdated, UUID, Updates);
do_update('server', UUID, Updates) ->
    gen_server:cast(?SERVER, {'channel_updates', UUID, Updates});
do_update(_Other, UUID, Updates) ->
    gen_server:cast(?SERVER, {'channel_updates', UUID, Updates}).

do_update_recording_status(UUID, RecordingID, RecordingState) ->
    Strategy = persistent_term:get('channels_update_strategy', 'server'),
    do_update_recording_status(Strategy, UUID, RecordingID, RecordingState).

do_update_recording_status('concurrency', UUID, RecordingID, RecordingEvent) ->
    set_channel_recording_status(UUID, RecordingID, RecordingEvent);
do_update_recording_status('server', UUID, RecordingID, RecordingEvent) ->
    gen_server:cast(?SERVER, {'channel_recording_update', UUID, RecordingID, RecordingEvent});
do_update_recording_status(_Other, UUID, RecordingID, RecordingEvent) ->
    gen_server:cast(?SERVER, {'channel_recording_update', UUID, RecordingID, RecordingEvent}).

set_channel_recording_status(UUID, RecordingID, RecordingEvent) ->
    case ecallmgr_fs_channel:fetch(UUID, 'record') of
        {'ok', #channel{recording_status=CurrentStatus}} ->
            CurrentReccordingState = kz_json:get_value(RecordingID, CurrentStatus),
            NewRecordingState = ecallmgr_fs_recordings:update_state(CurrentReccordingState, RecordingEvent),
            NewStatus = kz_json:set_value(RecordingID, NewRecordingState, CurrentStatus),
            WasUpdated = ets:update_element(?CHANNELS_TBL, UUID, {#channel.recording_status, NewStatus}),
            maybe_log_updates(WasUpdated, UUID, [{#channel.recording_status, NewStatus}]);
        _ -> lager:error("could not update recording status of channel ~s", [UUID])
    end.

do_channel_insert(Action, Channel) ->
    Strategy = persistent_term:get('channels_update_strategy', 'server'),
    do_channel_insert(Strategy, Action, Channel).

do_channel_insert('concurrency', 'new_channel', #channel{uuid=UUID}=Channel) ->
    case ets:insert_new(?CHANNELS_TBL, Channel) of
        'true'-> lager:debug("channel ~s added", [UUID]);
        'false' -> lager:debug("channel ~s already exists", [UUID])
    end;
do_channel_insert('concurrency', 'new_or_update', Channel) ->
    ets:insert(?CHANNELS_TBL, Channel);
do_channel_insert('server', Action, Channel) ->
    gen_server:call(?SERVER, {Action, Channel});
do_channel_insert(_Other, Action, Channel) ->
    gen_server:call(?SERVER, {Action, Channel}).

do_channel_destroy(UUID, Node) ->
    Strategy = persistent_term:get('channels_update_strategy', 'server'),
    do_channel_destroy(UUID, Node, Strategy).

do_channel_destroy(UUID, Node, 'concurrency') ->
    MatchSpec = channel_match_for_delete(UUID, Node),
    N = ets:select_delete(?CHANNELS_TBL, MatchSpec),
    lager:debug("removed ~p channel(s) with call-id ~s on ~s", [N, UUID, Node]);
do_channel_destroy(UUID, Node, 'server') ->
    gen_server:cast(?SERVER, {'destroy_channel', UUID, Node});
do_channel_destroy(UUID, Node, _Other) ->
    gen_server:cast(?SERVER, {'destroy_channel', UUID, Node}).

-spec set_channels_update_default_strategy() -> 'ok'.
set_channels_update_default_strategy() ->
    Strategy = kz_app_config:get_atom(?APP, [<<"channels">>, <<"update_strategy">>], 'server'),
    set_channels_update_strategy(Strategy).

-spec set_channels_update_strategy(term()) -> 'ok'.
set_channels_update_strategy(Strategy)
  when not is_atom(Strategy) ->
    set_channels_update_strategy(kz_term:to_atom(Strategy, 'true'));
set_channels_update_strategy(Strategy) ->
    persistent_term:put('channels_update_strategy', Strategy).

channel_match_for_delete(UUID, Node) ->
    [{#channel{uuid='$1', node='$2', _ = '_'}
     ,[{'andalso', {'=:=', '$2', {'const', Node}}
       ,{'=:=', '$1', UUID}}
      ],
      ['true']
     }].

-spec handle_count(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_count(JObj, _Props) ->
    'true' = kapi_call:count_req_v(JObj),
    Count = count(JObj),
    Resp = [{<<"Count">>, kz_json:from_map(Count)}
           ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    ServerId = kz_api:server_id(JObj),
    lager:debug("sending back count result to ~s", [ServerId]),
    kapi_call:publish_count_resp(ServerId, Resp).


-spec count(kz_json:object() | map()) -> map().
count(Map) when is_map(Map) ->
    AccountId = maps:get('account', Map),
    Direction = maps:get('direction', Map, 'undefined'),
    DeviceId = maps:get('device', Map, 'undefined'),
    EndpointId = maps:get('endpoint', Map,  'undefined'),
    OwnerId = maps:get('owner', Map,  'undefined'),
    UserId = maps:get('user', Map,  'undefined'),
    Routines = [{'account', AccountId, Direction, fun count_by_account_match_spec/2}
               ,{'device', {AccountId, DeviceId}, Direction, fun count_by_device_match_spec/2}
               ,{'endpoint', {AccountId, EndpointId}, Direction, fun count_by_endpoint_match_spec/2}
               ,{'owner', {AccountId, OwnerId}, Direction, fun count_by_owner_match_spec/2}
               ,{'user', {AccountId, UserId}, Direction, fun count_by_owner_match_spec/2}
               ],
    maps:from_list(lists:filtermap(fun count_fun/1, Routines));
count(JObj) ->
    Props = [{'account', kz_json:get_ne_binary_value(<<"Account-ID">>, JObj)}
            ,{'device', kz_json:get_ne_binary_value(<<"Device-ID">>, JObj)}
            ,{'endpoint', kz_json:get_ne_binary_value(<<"Endpoint-ID">>, JObj)}
            ,{'owner', kz_json:get_ne_binary_value(<<"Owner-ID">>, JObj)}
            ,{'user', kz_json:get_ne_binary_value(<<"User-ID">>, JObj)}
            ,{'direction', kz_json:get_ne_binary_value(<<"Direction">>, JObj)}
            ],
    count(maps:from_list(lists:filter(fun({_, V}) -> V =/= 'undefined' end, Props))).

-spec count(kz_term:ne_binary(), kz_term:ne_binary()) -> map().
count(AccountId, EndpointId) ->
    count(#{account => AccountId, endpoint => EndpointId}).

-spec count(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) -> map().
count(AccountId, OwnerId, DeviceId) ->
    count(#{account => AccountId, owner => OwnerId, device => DeviceId}).

-spec count(kz_term:ne_binary(), kz_term:api_ne_binary(), kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> map().
count(AccountId, OwnerId, DeviceId, Direction) ->
    count(#{account => AccountId, owner => OwnerId, device => DeviceId, direction => Direction}).

count_fun({_, 'undefined', _, _}) -> 'false';
count_fun({_, {_, 'undefined'}, _, _}) -> 'false';
count_fun({Header, Id, Direction, Fun}) ->
    MatchSpec = Fun(Id, Direction),
    {'true', {Header, length(ets:select(?CHANNELS_TBL, MatchSpec))}}.

count_by_account_match_spec(AccountId, 'undefined') ->
    [{#channel{uuid = '$1', account_id = '$2', _ = '_'}
     ,[{'=:=', '$2', {'const', AccountId}}]
     ,['$1']}
    ];
count_by_account_match_spec(AccountId, Direction) ->
    [{#channel{uuid = '$1', account_id = '$2', direction = '$3', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'=:=', '$3', {'const', Direction}}
       }
      ]
     ,['$1']}
    ].

count_by_owner_match_spec({AccountId, OwnerId}, 'undefined') ->
    [{#channel{uuid = '$1', account_id = '$2', owner_id = '$3', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'=:=', '$3', {'const', OwnerId}}
       }
      ]
     ,['$1']}
    ];
count_by_owner_match_spec({AccountId, OwnerId}, Direction) ->
    [{#channel{uuid = '$1', account_id = '$2', owner_id = '$3', direction = '$4', _ = '_'}
     ,[{'andalso',
        {'andalso',
         {'=:=', '$2', {'const', AccountId}},
         {'=:=', '$3', {'const', OwnerId}}
        }
       ,{'=:=', '$4', {'const', Direction}}
       }
      ]
     ,['$1']}
    ].

count_by_device_match_spec({AccountId, DeviceId}, 'undefined') ->
    [{#channel{uuid = '$1', account_id = '$2', authorizing_id = '$3', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'=:=', '$3', {'const', DeviceId}}
       }
      ]
     ,['$1']}
    ];
count_by_device_match_spec({AccountId, DeviceId}, Direction) ->
    [{#channel{uuid = '$1', account_id = '$2', authorizing_id = '$3', direction = '$4', _ = '_'}
     ,[{'andalso',
        {'andalso',
         {'=:=', '$2', {'const', AccountId}},
         {'=:=', '$3', {'const', DeviceId}}
        }
       ,{'=:=', '$4', {'const', Direction}}
       }
      ]
     ,['$1']}
    ].

count_by_endpoint_match_spec({AccountId, EndpointId}, 'undefined') ->
    [{#channel{uuid = '$1', account_id = '$2', authorizing_id = '$3', owner_id = '$4', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'orelse',
         {'=:=', '$3', {'const', EndpointId}}
        ,{'=:=', '$4', {'const', EndpointId}}
        }
       }
      ]
     ,['$1']}
    ];
count_by_endpoint_match_spec({AccountId, EndpointId}, Direction) ->
    [{#channel{uuid = '$1', account_id = '$2', authorizing_id = '$3', owner_id = '$4', direction = '$5', _ = '_'}
     ,[{'andalso',
        {'andalso',
         {'=:=', '$2', {'const', AccountId}},
         {'orelse',
          {'=:=', '$3', {'const', EndpointId}}
         ,{'=:=', '$4', {'const', EndpointId}}
         }
        }
       ,{'=:=', '$5', {'const', Direction}}
       }
      ]
     ,['$1']}
    ].


-spec handle_channels(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_channels(JObj, _Props) ->
    'true' = kapi_call:channels_req_v(JObj),
    Channels = channels(JObj),
    Resp = [{<<"Channels">>, kz_json:from_map(Channels)}
           ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    ServerId = kz_api:server_id(JObj),
    lager:debug("sending back channels result to ~s", [ServerId]),
    kapi_call:publish_channels_resp(ServerId, Resp).

field_mapper(Map) ->
    field_mapper_fun(fields(Map)).

fields(Map) ->
    case maps:get(fields, Map, undefined) of
        List when is_list(List) -> [kz_term:to_atom(Item) || Item <- List];
        _Other -> default_fields()
    end.

default_fields() ->
    [switch_url
    ,is_onhold
    ,destination
    ,other_leg
    ].

field_mapper_fun(RequestedFields) ->
    Fields = lists:zip(lists:seq(2, record_info(size, channel)), record_info(fields, channel)),
    FilteredFields = lists:filter(fun({_, Name}) -> lists:member(Name, RequestedFields) end, Fields),
    fun(Record) ->
            lists:foldl(fun({I, E}, Acc) -> Acc#{E => element(I, Record) } end, #{}, FilteredFields)
    end.

channels_query_arg(Arg, Map) ->
    case maps:get(Arg, Map,  undefined) of
        EndpointId when is_binary(EndpointId) -> list_to_tuple(binary:split(EndpointId, <<"@">>));
        Endpoint when is_tuple(Endpoint) -> Endpoint;
        _Other -> undefined
    end.

-spec channels(kz_json:object() | map()) -> map().
channels(Map) when is_map(Map) ->
    Account = maps:get('account', Map, 'undefined'),
    Direction = maps:get('direction', Map, 'undefined'),
    Mapper = field_mapper(Map),
    Routines = [{'account', Account, Direction, fun account_match_spec/2, Mapper}
               ,{'device', channels_query_arg(device, Map), Direction, fun device_match_spec/2, Mapper}
               ,{'endpoint', channels_query_arg(endpoint, Map), Direction, fun endpoint_match_spec/2,Mapper}
               ,{'owner', channels_query_arg(owner, Map), Direction, fun owner_match_spec/2, Mapper}
               ,{'user', channels_query_arg(user, Map), Direction, fun owner_match_spec/2, Mapper}
               ],
    maps:from_list(lists:filtermap(fun channels_fun/1, Routines));
channels(JObj) ->
    Props = [{'account', kz_json:get_ne_binary_value(<<"Account-ID">>, JObj)}
            ,{'device', kz_json:get_ne_binary_value(<<"Device-ID">>, JObj)}
            ,{'endpoint', kz_json:get_ne_binary_value(<<"Endpoint-ID">>, JObj)}
            ,{'owner', kz_json:get_ne_binary_value(<<"Owner-ID">>, JObj)}
            ,{'user', kz_json:get_ne_binary_value(<<"User-ID">>, JObj)}
            ,{'direction', kz_json:get_ne_binary_value(<<"Direction">>, JObj)}
            ,{'fields', kz_json:get_ne_binaries(<<"Fields">>, JObj)}
            ],
    channels(maps:from_list(lists:filter(fun({_, V}) -> V =/= 'undefined' end, Props))).

-spec channels(kz_term:ne_binary(), kz_term:ne_binary()) -> map().
channels(AccountId, EndpointId) ->
    channels(#{account => AccountId, endpoint => EndpointId}).

-spec channels(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) -> map().
channels(AccountId, OwnerId, DeviceId) ->
    channels(#{account => AccountId, owner => OwnerId, device => DeviceId}).

-spec channels(kz_term:ne_binary(), kz_term:api_ne_binary(), kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> map().
channels(AccountId, OwnerId, DeviceId, Direction) ->
    channels(#{account => AccountId, owner => OwnerId, device => DeviceId, direction => Direction}).

channels_fun({_, undefined, _, _, _}) -> false;
channels_fun({_, {_, undefined}, _, _, _}) -> false;
channels_fun({Header, Id, Direction, Fun, Mapper}) ->
    MatchSpec = Fun(Id, Direction),
    {true, {Header, channels_map(ets:select(?CHANNELS_TBL, MatchSpec), Mapper)}}.

channels_map(Channels, Mapper) ->
    lists:foldl(fun(#channel{uuid = UUID} = Record, Acc) -> Acc#{UUID => Mapper(Record)} end, #{}, Channels).

account_match_spec(AccountId, 'undefined') ->
    [{#channel{account_id = '$2', _ = '_'}
     ,[{'=:=', '$2', {'const', AccountId}}]
     ,['$_']}
    ];
account_match_spec(AccountId, Direction) ->
    [{#channel{account_id = '$2', direction = '$3', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'=:=', '$3', {'const', Direction}}
       }
      ]
     ,['$_']}
    ].

owner_match_spec({OwnerId, AccountId}, 'undefined') ->
    [{#channel{account_id = '$2', owner_id = '$3', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'=:=', '$3', {'const', OwnerId}}
       }
      ]
     ,['$_']}
    ];
owner_match_spec({OwnerId, AccountId}, Direction) ->
    [{#channel{account_id = '$2', owner_id = '$3', direction = '$4', _ = '_'}
     ,[{'andalso',
        {'andalso',
         {'=:=', '$2', {'const', AccountId}},
         {'=:=', '$3', {'const', OwnerId}}
        }
       ,{'=:=', '$4', {'const', Direction}}
       }
      ]
     ,['$_']}
    ].

device_match_spec({DeviceId, AccountId}, 'undefined') ->
    [{#channel{account_id = '$2', authorizing_id = '$3', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'=:=', '$3', {'const', DeviceId}}
       }
      ]
     ,['$_']}
    ];
device_match_spec({DeviceId, AccountId}, Direction) ->
    [{#channel{account_id = '$2', authorizing_id = '$3', direction = '$4', _ = '_'}
     ,[{'andalso',
        {'andalso',
         {'=:=', '$2', {'const', AccountId}},
         {'=:=', '$3', {'const', DeviceId}}
        }
       ,{'=:=', '$4', {'const', Direction}}
       }
      ]
     ,['$_']}
    ].

endpoint_match_spec({EndpointId, AccountId}, 'undefined') ->
    [{#channel{account_id = '$2', authorizing_id = '$3', owner_id = '$4', _ = '_'}
     ,[{'andalso',
        {'=:=', '$2', {'const', AccountId}},
        {'orelse',
         {'=:=', '$3', {'const', EndpointId}}
        ,{'=:=', '$4', {'const', EndpointId}}
        }
       }
      ]
     ,['$_']}
    ];
endpoint_match_spec({EndpointId, AccountId}, Direction) ->
    [{#channel{account_id = '$2', authorizing_id = '$3', owner_id = '$4', direction = '$5', _ = '_'}
     ,[{'andalso',
        {'andalso',
         {'=:=', '$2', {'const', AccountId}},
         {'orelse',
          {'=:=', '$3', {'const', EndpointId}}
         ,{'=:=', '$4', {'const', EndpointId}}
         }
        }
       ,{'=:=', '$5', {'const', Direction}}
       }
      ]
     ,['$_']}
    ].
