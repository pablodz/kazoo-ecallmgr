%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_conferences_shared).

-behaviour(gen_listener).

-export([start_link/0
        ,handle_dial_req/2
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

-define(RESPONDERS, [{{?MODULE, 'handle_dial_req'}
                     ,[{<<"conference">>, <<"command">>}]
                     }
                    ]).
-define(BINDINGS, [{'conference', [{'restrict_to', [{'command', kz_config:zone('binary')}]}
                                  ,'federate'
                                  ]}
                  ]).
-define(QUEUE_NAME, <<?MODULE_STRING>>).
-define(QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(CONSUME_OPTIONS, [{'exclusive', 'false'}]).

-type state() :: 'ok'.

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_listener:start_link({'local', ?MODULE}, ?MODULE,
                            [{'responders', ?RESPONDERS}
                            ,{'bindings', ?BINDINGS}
                            ,{'queue_name', ?QUEUE_NAME}
                            ,{'queue_options', ?QUEUE_OPTIONS}
                            ,{'consume_options', ?CONSUME_OPTIONS}
                            ], []).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    {'ok', 'ok'}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Req, _From, State) ->
    lager:debug("unhandled call from ~p: ~p", [_From, _Req]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast(_Req, State) ->
    lager:debug("unhandled cast: ~p", [_Req]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Msg, State) ->
    lager:debug("unhandled msg: ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> gen_listener:handle_event_return().
handle_event(_JObj, _State) ->
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
terminate(_Reason, _State) ->
    lager:debug("conferences listener going down: ~p", [_Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) -> {'ok', State}.

-spec handle_dial_req(kapi_conference:doc(), kz_term:proplist()) -> 'ok'.
handle_dial_req(JObj, _Props) ->
    'true' = kapi_conference:dial_v(JObj),
    ConferenceId = kz_json:get_ne_binary_value(<<"Conference-ID">>, JObj),
    case ecallmgr_fs_conferences:node(ConferenceId) of
        {'error', 'not_found'} ->
            maybe_start_conference(JObj, ConferenceId);
        {'ok', ConferenceNode} ->
            exec_dial(ConferenceNode, ConferenceId, JObj)
    end,
    lager:debug("finished dialing").

-spec exec_dial(atom(), kz_term:ne_binary(), kapi_conference:doc()) -> 'ok'.
exec_dial(ConferenceNode, ConferenceId, JObj) ->
    Endpoints = kz_json:get_list_value(<<"Endpoints">>, JObj, []),
    exec_dial(ConferenceNode, ConferenceId, JObj, Endpoints).

-spec exec_dial(atom(), kz_term:ne_binary(), kapi_conference:doc(), kz_json:objects()) -> 'ok'.
exec_dial(ConferenceNode, ConferenceId, JObj, Endpoints) ->
    lager:info("conference ~s is running on ~s, dialing out", [ConferenceId, ConferenceNode]),
    Pid = self(),
    IteractionId = ?CALL_INTERACTION_DEFAULT,
    Pids = [kz_process:spawn(fun() ->
                                     exec_endpoint(Pid, ConferenceNode, ConferenceId, IteractionId, JObj, Endpoint)
                             end) || Endpoint <- Endpoints],
    Num = length(Pids),
    handle_responses(JObj, Num, []).


-spec handle_responses(kapi_conference:doc(), integer(), kz_json:objects()) -> 'ok'.
handle_responses(JObj, N, Responses)
  when N =:= 0 ->
    publish_resp(JObj, Responses);
handle_responses(JObj, N, Responses) ->
    receive
        {'result', Response} -> handle_responses(JObj, N - 1, [Response | Responses])
    end.

update_endpoint(Endpoint, InteractionId) ->
    Updates = [{fun kz_json:set_value/3, [<<"Custom-Channel-Vars">>, <<"Ecallmgr-Node">>], node()}
              ,{fun kz_json:set_value/3, [<<"Custom-Channel-Vars">>, <<"Ignore-Early-Media">>], 'true'}
              ,{fun kz_json:set_value/3, [<<"Custom-Channel-Vars">>, <<"Call-Flag-NO-Flip">>], 'true'}
              ,{fun kz_json:set_value/3, [<<"Custom-Channel-Vars">>, <<?CALL_INTERACTION_ID>>], InteractionId}
              ],
    lists:foldl(fun({F, K, V}, JObj) -> F(K, V, JObj) end, Endpoint, Updates).

endpoint_id(JObj) ->
    Keys = [<<"Route">>
           ,<<"Endpoint-ID">>
           ,[<<"Custom-Channel-Vars">>, <<"Authorizing-ID">>]
           ],
    kz_json:get_first_defined(Keys, JObj).

-spec exec_endpoint(pid(), atom(), kz_term:ne_binary(), kz_term:ne_binary(), kapi_conference:doc(), kz_json:object()) -> any().
exec_endpoint(Parent, ConferenceNode, ConferenceId, InteractionId, JObj, EP) ->
    EndpointCallId = kz_json:find(<<"Outbound-Call-ID">>, [EP, JObj], kz_binary:rand_hex(16)),
    Endpoint = update_endpoint(EP, InteractionId),
    EndpointId = endpoint_id(Endpoint),
    lager:debug("endpoint ~s(~s)", [EndpointId, EndpointCallId]),
    _ = (catch gproc:reg({'p', 'l', ?FS_CONFERENCE_EVENT_REG_MSG(ConferenceNode, ConferenceId, <<"add-member">>)})),
    _ = (catch gproc:reg({'p', 'l', ?FS_CONFERENCE_EVENT_REG_MSG(ConferenceNode, ConferenceId, <<"bgdial-result">>)})),
    _ = (catch gproc:reg({'p', 'l', ?FS_EVENT_REG_MSG_UUID(ConferenceNode, <<"CHANNEL_REPLACED">>)})),

    try ecallmgr_conference_command:dial(ConferenceNode
                                        ,ConferenceId
                                        ,JObj
                                        ,Endpoint
                                        )
    of
        {'ok', <<"Job-UUID: ", JobId/binary>>} ->
            lager:info("starting dial resulted in job-id ~s", [JobId]),
            Timeout = kz_json:get_integer_value(<<"Timeout">>, JObj) * ?MILLISECONDS_IN_SECOND,
            wait_for_dial_result(Parent, EndpointId, JobId, EndpointCallId, Timeout);
        _E ->
            lager:info("failed to exec: ~p", [_E]),
            Parent ! {'result', error_resp(EndpointId, <<"unknown failure">>)}
    catch
        'throw':{'msg', E} ->
            lager:info("failed to exec: ~p", [E]),
            Parent ! {'result', error_resp(EndpointId, E)};
        'throw':Msg when is_binary(Msg) ->
            lager:info("failed to exec: ~s", [Msg]),
            Parent ! {'result', error_resp(EndpointId, Msg)}
    end.

wait_for_dial_result(Parent, EndpointId, JobId, EndpointCallId, Timeout) ->
    receive
        {'event', <<"CHANNEL_DESTROY">>, EndpointCallId, JObj} ->
            Parent ! {'result', error_resp(EndpointId, kz_evt_freeswitch:hangup_cause(JObj))};
        {'event', <<"CHANNEL_REPLACED">>, EndpointCallId, JObj} ->
            UUID = kz_json:get_ne_binary_value(<<"Acquired-UUID">>, JObj),
            Node = kz_api:node(JObj),
            lager:debug("bdial-result call-id ~s replaced by ~s", [EndpointCallId, UUID]),
            _ = (catch gproc:reg({'p', 'l', ?FS_CALL_EVENT_MSG(Node, <<"CHANNEL_DESTROY">>, UUID)})),
            wait_for_dial_result(Parent, EndpointId, JobId, UUID, Timeout);
        {'event', <<"CHANNEL_REPLACED">>, _OtherUUID, _JObj} ->
            lager:debug("received replaced for another uuid ~s", [_OtherUUID]),
            wait_for_dial_result(Parent, EndpointId, JobId, EndpointCallId, Timeout);
        ?FS_CONFERENCE_EVENT_MSG(_ConferenceId, <<"bgdial-result">>, JObj) ->
            case kz_json:get_ne_binary_value([<<"Dial-Result">>, <<"Job-UUID">>], JObj) of
                JobId ->
                    case kz_json:get_ne_binary_value([<<"Dial-Result">>, <<"Result">>], JObj) of
                        <<"SUCCESS">> ->
                            UUID = kz_json:get_ne_binary_value([<<"Dial-Result">>, <<"Peer-UUID">>], JObj),
                            wait_for_dial_result(Parent, EndpointId, JobId, UUID, Timeout);
                        Error ->
                            Parent ! {'result', error_resp(EndpointId, Error)}
                    end;
                _Other ->
                    lager:debug("received bgdial-result for another jobid ~s", [_Other]),
                    wait_for_dial_result(Parent, EndpointId, JobId, EndpointCallId, Timeout)
            end;
        ?FS_CONFERENCE_EVENT_MSG(_ConferenceId, <<"add-member">>, _JObj) ->
            Parent ! {'result', success_resp(EndpointId, EndpointCallId)}
    after Timeout ->
            lager:info("timed out waiting for ~s/~s", [JobId, EndpointCallId]),
            Parent ! {'result', error_resp(EndpointId, <<"timeout">>)}
    end.

-spec success_resp(kz_term:ne_binary(), kz_term:ne_binary()) -> kz_json:object().
success_resp(EndpointId, CallId) ->
    kz_json:from_list([{<<"Message">>, <<"dialing endpoints">>}
                      ,{<<"Status">>, <<"success">>}
                      ,{<<"Endpoint-ID">>, EndpointId}
                      ,{<<"Call-ID">>, CallId}
                      ]).

-spec error_resp(kz_term:ne_binary(), kz_term:ne_binary()) -> kz_json:object().
error_resp(EndpointId, Error) ->
    kz_json:from_list([{<<"Status">>, <<"error">>}
                      ,{<<"Message">>, Error}
                      ,{<<"Endpoint-ID">>, EndpointId}
                      ]).

-spec publish_resp(kapi_conference:doc(), kz_json:objects()) -> 'ok'.
publish_resp(JObj, BaseResps) ->
    Resp = [{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           ,{<<"Endpoint-Responses">>, BaseResps}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kz_amqp_worker:cast(Resp
                       ,fun(P) -> kapi_conference:publish_dial_resp(kz_api:server_id(JObj), P) end
                       ).

-spec publish_error(kapi_conference:doc(), kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
publish_error(JObj, ConferenceId, Error) ->
    Resp = [{<<"Msg-ID">>, kz_api:msg_id(JObj)}
           ,{<<"Conference-ID">>, ConferenceId}
           ,{<<"Error-Message">>, Error}
           ,{<<"Request">>, kz_api:remove_defaults(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kapi_conference:publish_error(kz_api:server_id(JObj), Resp).

-spec maybe_start_conference(kapi_conference:doc(), kz_term:ne_binary()) -> 'ok'.
maybe_start_conference(JObj, ConferenceId) ->
    lager:info("conference ~s is not running yet", [ConferenceId]),
    case find_media_server(kz_json:get_ne_binary_value(<<"Target-Call-ID">>, JObj), kz_api:node(JObj)) of
        'undefined' ->
            lager:info("no node found for the dial command, sending error"),
            publish_error(JObj, ConferenceId, <<"no media servers available">>);
        MediaServer ->
            lager:info("starting conference ~s on ~s and dialing out", [ConferenceId, MediaServer]),
            exec_dial(MediaServer, ConferenceId, JObj)
    end.

-spec find_media_server(kz_term:api_ne_binary(), kz_term:ne_binary()) -> atom().
find_media_server('undefined', IssuerNode) ->
    IssuerNodeInfo = kz_nodes:node_to_json(IssuerNode),
    MyZone = kz_config:zone('binary'),

    case kz_json:get_ne_binary_value(<<"zone">>, IssuerNodeInfo) of
        MyZone -> choose_random_media_server();
        _IssuerZone ->
            lager:info("issuer ~s is in zone ~s, ignoring request", [IssuerNode, _IssuerZone]),
            'undefined'
    end;
find_media_server(TargetCallId, IssuerNode) ->
    case ecallmgr_fs_channel:node(TargetCallId) of
        {'ok', Node} -> Node;
        {'error', 'not_found'} ->
            lager:info("failed to find node of target call-id ~s, querying cluster", [TargetCallId]),
            case query_cluster_for_call(TargetCallId) of
                {'ok', StatusJObjs} ->
                    find_media_server_from_statuses(TargetCallId, IssuerNode, StatusJObjs);
                _E ->
                    lager:info("failed to query for ~s: ~p", [TargetCallId, _E]),
                    find_media_server('undefined', IssuerNode)
            end
    end.

-spec find_media_server_from_statuses(kz_term:ne_binary(), kz_term:ne_binary(), kz_json:objects()) -> atom().
find_media_server_from_statuses(TargetCallId, IssuerNode, []) ->
    lager:info("no one has record of ~s", [TargetCallId]),
    find_media_server('undefined', IssuerNode);
find_media_server_from_statuses(TargetCallId, IssuerNode, [Status|Statuses]) ->
    case kz_json:get_ne_binary_value([<<"Channels">>, TargetCallId, <<"Media-Node">>], Status) of
        'undefined' -> find_media_server_from_statuses(TargetCallId, IssuerNode, Statuses);
        MediaServer ->
            lager:info("found ~s on ~s", [TargetCallId, MediaServer]),
            case lists:filter(fun(MS) -> kz_term:to_binary(MS) =:= MediaServer end
                             ,ecallmgr_fs_nodes:connected()
                             )
            of
                [] ->
                    lager:info("media server ~s is not managed by us, not starting conference"
                              ,[MediaServer]
                              ),
                    'undefined';
                [MS] ->
                    lager:info("media server ~s is managed by us!", [MediaServer]),
                    MS
            end
    end.

-spec query_cluster_for_call(kz_term:ne_binary()) -> {'ok', kz_json:objects()} |
          {'error', any()}.
query_cluster_for_call(CallId) ->
    Req = [{<<"Call-ID">>, CallId}
          ,{<<"Fields">>, <<"all">>}
          ,{<<"Active-Only">>, 'true'}
          | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],

    kz_amqp_worker:call_collect(Req
                               ,fun kapi_call:publish_query_channels_req/1
                               ,{'ecallmgr', fun kapi_call:query_channels_resp_v/1}
                               ).

-spec choose_random_media_server() -> atom().
choose_random_media_server() ->
    case ecallmgr_fs_nodes:connected() of
        [] -> 'undefined';
        Servers -> hd(kz_term:shuffle_list(Servers))
    end.
