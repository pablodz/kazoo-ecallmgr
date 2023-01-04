%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc Receive route(dialplan) requests from FS, request routes and respond
%%%
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fetch_dialplan).

-export([init/0]).
-export([dialplan/1]).
-export([route_winner/1]).

-include("ecallmgr.hrl").

-define(ROUTE_WINNER_TIMEOUT, 60 * ?MILLISECONDS_IN_SECOND).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"fetch.dialplan.*.route_req.*">>, ?MODULE, 'dialplan'),
    _ = kazoo_bindings:bind(<<"event_stream.event.dialplan.ROUTE_WINNER">>, ?MODULE, 'route_winner'),
    'ok'.

-spec dialplan(dialplan_context()) -> {'ok', dialplan_context()}.
dialplan(#{node := Node, fetch_id := FetchId, payload := FetchJObj}=Map) ->
    kz_log:put_callid(FetchJObj),
    lager:debug("received dialplan fetch request ~s from ~s"
               ,[FetchId, Node]
               ),
    Routines = [fun call_id/1
               ,fun timeout/1
               ,{fun add_time_marker/2, 'start_processing'}
               ,fun init_kazoo/1
               ],
    {'ok', kz_maps:exec(Routines, Map)}.

-spec init_kazoo(dialplan_context()) -> dialplan_context().
init_kazoo(M) ->
    M1 = M#{channel => kz_amqp_channel:consumer_channel()
           ,callback => fun process/1
           ,options => []
           },
    M1#{start_result => ecallmgr_call_control_manager:start_call_control(M1)}.

-spec process(dialplan_context()) -> {'ok', dialplan_context()}.
process(#{payload := FetchJObj, channel := Channel}=Map) ->
    kz_log:put_callid(FetchJObj),
    _ = kz_amqp_channel:consumer_channel(Channel),
    Routines = [{fun add_time_marker/2, 'request_ready'}
               ,fun control_p/1
               ,fun request/1
               ,fun request_headers/1
               ,fun is_quickrouted/1
               ,fun block_call_routines/1
               ,fun apply_formatters/1
               ,fun maybe_authz/1
               ],
    maybe_expired(kz_maps:exec(Routines, Map)).

-spec request(dialplan_context()) -> dialplan_context().
request(#{request := _Request}=Map) -> Map;
request(#{control_q := ControlQ, control_p := ControlP, payload := FetchJObj}=Map) ->
    Map#{request => kz_json:set_value(?KEY_SERVER_ID, kapi:encode_pid(ControlQ, ControlP), FetchJObj)}.

-spec request_headers(dialplan_context()) -> dialplan_context().
request_headers(#{request_headers := _}=Map) -> Map;
request_headers(#{call_id := CallId, core_uuid := CoreUUID}=Map) ->
    Headers = [{<<"call-id">>, 'binary', CallId}
              ,{<<"core-uuid">>, 'binary', kz_term:to_binary(CoreUUID)}
              ],
    KAPIHeaders = [{'headers', Headers}],
    Map#{request_headers => KAPIHeaders}.

-spec control_p(dialplan_context()) -> dialplan_context().
control_p(#{control_p := _Pid}=Map) -> Map;
control_p(Map) ->
    Map#{control_p => self()}.

-spec timeout(dialplan_context()) -> dialplan_context().
timeout(#{timeout := _Timeout}=Map) -> Map;
timeout(#{payload := FetchJObj}=Map) ->
    NowUs = erlang:system_time('micro_seconds'),
    T0 = kzd_fetch:fetch_timestamp_micro(FetchJObj, NowUs),
    T1 = kzd_fetch:fetch_timeout(FetchJObj, 3500000),
    T4 = NowUs - T0,
    T5 = T1 - T4,
    T6 = T5 div 1000,
    Map#{timeout => T6 - 750}.

-spec call_id(dialplan_context()) -> dialplan_context().
call_id(#{call_id := _CallId}=Map) -> Map;
call_id(#{payload := JObj}=Map) ->
    Map#{call_id => kzd_fetch:call_id(JObj)}.

-spec add_time_marker(dialplan_context(), atom()) -> dialplan_context().
add_time_marker(Map, Name) ->
    add_time_marker(Map, Name, kz_time:now_us()).

-spec add_time_marker(dialplan_context(), atom(), pos_integer()) -> dialplan_context().
add_time_marker(#{timer := Timer}= Map, Name, Value) ->
    Map#{timer => Timer#{Name => Value}};
add_time_marker(#{}= Map, Name, Value) ->
    add_time_marker(Map#{timer => #{}}, Name, Value).

-spec maybe_authz(dialplan_context()) -> dialplan_context().
maybe_authz(#{blocked := 'true'}=Map) -> Map;
maybe_authz(#{reply := #{payload := _Payload}}=Map) -> Map;
maybe_authz(#{authz_worker := _Authz}=Map) -> Map;
maybe_authz(#{}=Map) ->
    case kapps_config:is_true(?APP_NAME, <<"authz_enabled">>, 'false') of
        'true' -> spawn_authorize_call_fun(Map);
        'false' -> Map
    end.

-spec maybe_expired(dialplan_context()) -> {'ok', dialplan_context()}.
maybe_expired(#{timeout := Timeout}=Map)
  when Timeout =< 0 ->
    maybe_expired(Map#{timeout => 5 * ?MILLISECONDS_IN_SECOND});
%%     lager:warning("timeout before sending route request : ~B", [Timeout]),
%%     send_reply(Map);
maybe_expired(Map) ->
    maybe_blocked(Map).

-spec maybe_blocked(dialplan_context()) -> {'ok', dialplan_context()}.
maybe_blocked(#{blocked := 'true'}=Map) ->
    send_reply(Map);
maybe_blocked(#{reply := #{payload := _Payload}}=Map) ->
    send_reply(Map);
maybe_blocked(#{request := Request, request_headers := Headers}=Map) ->
    kapi_route:publish_req(Request, Headers),
    wait_for_route_resp(add_time_marker(timeout_reply(Map), 'request_sent')).

-spec wait_for_route_resp(dialplan_context()) -> {'ok', dialplan_context()}.
wait_for_route_resp(#{timeout := TimeoutMs, fetch_id := FetchId}=Map) ->
    lager:debug("waiting ~B ms for route response to request ~s"
               ,[TimeoutMs, FetchId]
               ),
    StartTime = kz_time:start_time(),
    receive
        {'kapi', {_, {'dialplan', 'route_resp'}, Resp}} ->
            case kz_api:defer_response(Resp) of
                'true' ->
                    NewTimeoutMs = TimeoutMs - kz_time:elapsed_ms(StartTime),
                    lager:debug("received deferred reply for ~s - waiting for others for ~B ms"
                               ,[FetchId, NewTimeoutMs]
                               ),
                    wait_for_route_resp(Map#{timeout => NewTimeoutMs
                                            ,reply => #{payload => Resp}
                                            }
                                       );
                'false' ->
                    lager:info("received route reply for ~s", [FetchId]),
                    NewTimeoutMs = TimeoutMs - kz_time:elapsed_ms(StartTime),
                    maybe_wait_for_authz(Map#{reply => #{payload => Resp}
                                             ,authz_timeout => NewTimeoutMs
                                             }
                                        )
            end
    after TimeoutMs ->
            lager:warning("timeout after ~B receiving route response for ~s"
                         ,[TimeoutMs, FetchId]
                         ),
            send_reply(Map)
    end.

-spec spawn_authorize_call_fun(dialplan_context()) -> dialplan_context().
spawn_authorize_call_fun(#{node := Node, call_id := CallId, payload := JObj}=Map) ->
    Ref = make_ref(),
    Pid = kz_process:spawn(fun authorize_call_fun/5, [self(), Ref, Node, CallId, JObj]),
    Map#{authz_worker => {Pid, Ref}}.

-spec authorize_call_fun(pid(), Ref, atom(), kz_term:ne_binary(), kz_json:object()) ->
          {'authorize_reply', Ref, ecallmgr_fs_authz:authz_reply()}
              when Ref :: reference().
authorize_call_fun(Parent, Ref, Node, CallId, JObj) ->
    kz_log:put_callid(CallId),
    Parent ! {'authorize_reply', Ref, ecallmgr_fs_authz:authorize(JObj, CallId, Node)}.

-spec maybe_wait_for_authz(dialplan_context()) -> {'ok', dialplan_context()}.
maybe_wait_for_authz(#{authz_worker := _AuthzWorker, reply := #{payload := Reply}}=Map) ->
    case kz_json:get_value(<<"Method">>, Reply) =/= <<"error">> of
        'true' -> wait_for_authz(Map);
        'false' -> send_reply(Map)
    end;
maybe_wait_for_authz(#{}=Map) ->
    send_reply(Map).

-spec wait_for_authz(dialplan_context()) -> {'ok', dialplan_context()}.
wait_for_authz(#{authz_worker := {Pid, Ref}
                ,authz_timeout := Timeout
                ,reply := #{payload := JObj}=Reply
                ,fetch_id := FetchId
                }=Map) ->
    lager:info("waiting for authz reply ~s from worker ~p"
              ,[FetchId, Pid]
              ),
    receive
        {'authorize_reply', Ref, 'false'} -> send_reply(forbidden_reply(Map));
        {'authorize_reply', Ref, 'true'} -> send_reply(Map);
        {'authorize_reply', Ref, {'true', AuthzCCVs}} ->
            CCVs = kz_json:get_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new()),
            J = kz_json:set_value(<<"Custom-Channel-Vars">>
                                 ,kz_json:merge_jobjs(CCVs, AuthzCCVs)
                                 ,JObj
                                 ),
            send_reply(Map#{reply => Reply#{payload => J}})
    after Timeout ->
            lager:warning("timeout waiting for authz reply ~s from worker ~p"
                         ,[FetchId, Pid]
                         ),
            {'ok', Map}
    end.

-spec send_reply(dialplan_context()) -> {'ok', dialplan_context()}.
send_reply(#{node := Node, fetch_id := FetchId, reply := #{payload := Reply}}=Context) ->
    {'ok', XML} = ecallmgr_fs_xml:route_resp_xml('dialplan', Reply, Context),
    lager:debug("sending xml dialplan reply for request ~s to ~s", [FetchId, Node]),
    _ = freeswitch:fetch_reply(Context#{reply => iolist_to_binary(XML)}),

    case kz_api:defer_response(Reply)
        orelse kz_json:get_ne_binary_value(<<"Method">>, Reply) =/= <<"park">>
    of
        'true' -> {'ok', Context};
        'false' -> wait_for_route_winner(Context)
    end.

-spec wait_for_route_winner(dialplan_context()) -> {'ok', dialplan_context()}.
wait_for_route_winner(#{fetch_id := FetchId}=Context) ->
    StartTime = kz_time:start_time(),
    receive
        {'kapi', {{_, _, {Basic, _}}, {'dialplan', 'ROUTE_WINNER'}, JObj}} ->
            CreatedUnix = kz_json:get_integer_value(<<"Timestamp-Unix">>, JObj),
            Created = kz_time:unix_us_to_gregorian_us(CreatedUnix),
            PublishedUnix = kz_amqp_basic:timestamp(Basic),
            Published = kz_time:unix_us_to_gregorian_us(PublishedUnix),
            Elapsed = kz_time:elapsed_us(StartTime),
            Delayed = kz_time:elapsed_us(Published),
            Fired = kz_time:elapsed_us(Created),
            lager:debug("route_win received after ~bμ , delayed by ~bμ, created ~bμ", [Elapsed, Delayed, Fired]),
            activate_call_control(Context#{winner => #{payload => JObj}});
        {'route_winner', JObj, _Props} ->
            activate_call_control(Context#{winner => #{payload => JObj}})
    after ?ROUTE_WINNER_TIMEOUT ->
            lager:warning("timeout after ~B receiving route winner for ~s"
                         ,[?ROUTE_WINNER_TIMEOUT, FetchId]
                         ),
            {'ok', Context}
    end.

-spec activate_call_control(dialplan_context()) -> {'ok', dialplan_context()}.
activate_call_control(#{call_id := CallId, fetch_id := FetchId, winner := #{payload := JObj}} = Map) ->
    lager:info("we are the route winner handling request ~s", [FetchId]),
    kz_log:put_callid(CallId),
    CCVs = kzd_fetch:ccvs(JObj),
    ControllerQ = kzd_fetch:controller_queue(JObj),
    ecallmgr_fs_channels:update(CallId, #channel.handling_locally, 'true'),
    Args = Map#{controller_q => ControllerQ
               ,initial_ccvs => CCVs
               },
    {'ok', Args}.

error_message() ->
    error_message(<<"no available handlers">>).

error_message(ErrorMsg) ->
    error_message(<<"604">>, ErrorMsg).

error_message(ErrorCode, ErrorMsg) ->
    kz_json:from_list([{<<"Method">>, <<"error">>}
                      ,{<<"Route-Error-Code">>, ErrorCode}
                      ,{<<"Route-Error-Message">>, ErrorMsg}
                      ]).

-spec timeout_reply(dialplan_context()) -> dialplan_context().
timeout_reply(#{blocked := 'true'} = Map) -> Map;
timeout_reply(#{reply := #{payload := _Payload}}=Map) -> Map;
timeout_reply(Map) ->
    Map#{reply => #{payload => error_message()}}.

-spec forbidden_reply(dialplan_context()) -> dialplan_context().
forbidden_reply(#{fetch_id := FetchId}=Map) ->
    lager:info("received forbidden route response for ~s, sending 403 Incoming call barred", [FetchId]),
    Map#{reply => #{payload => error_message(<<"403">>, <<"Incoming call barred">>)}}.

-spec route_winner(dialplan_context()) -> 'ok'.
route_winner(#{payload := JObj}) ->
    NodeWinner = kzd_fetch:ccv(JObj, <<"Ecallmgr-Node">>),
    case NodeWinner =:= kz_term:to_binary(node()) of
        'true' ->
            Pid = kz_term:to_pid(kz_api:reply_to(JObj)),
            Pid ! {'route_winner', JObj, []};
        'false' ->
            lager:info("route request ~s handled by other node : ~s", [kzd_fetch:fetch_uuid(JObj), NodeWinner])
    end.

-spec block_call_routines(dialplan_context()) -> dialplan_context().
block_call_routines(Map) ->
    Routines = [{fun should_block_anonymous/1, {<<"433">>, <<"Anonymity Disallowed">>}}
               ,{fun is_blacklisted/1, {<<"603">>, <<"Decline">>}}
               ],
    lists:foldl(fun block_call_routine/2, Map, Routines).

-type block_call_fun() :: fun((kz_json:object()) -> boolean()).
-type block_call_resp() :: {kz_term:ne_binary(), kz_term:ne_binary()}.
-type block_call_arg() :: {block_call_fun(), block_call_resp()}.

-spec block_call_routine(block_call_arg(), dialplan_context()) -> dialplan_context().
block_call_routine({_Fun, {_Code, _Msg}}, #{blocked := 'true'}=Map) -> Map;
block_call_routine({Fun, {Code, Msg}}, #{request := JObj}=Map) ->
    case Fun(JObj) of
        'false' -> Map;
        'true' ->
            Map#{reply => #{payload => error_message(Code, Msg)}
                ,blocked => 'true'
                }
    end.

is_quickrouted(#{request := JObj}=Map) ->
    [RequestUser, _RequestRealm] = binary:split(kz_json:get_ne_binary_value(<<"Request">>, JObj), <<"@">>),
    [ToUser, _ToRealm] = binary:split(kz_json:get_ne_binary_value(<<"To">>, JObj), <<"@">>),
    CalleeNumber = kz_json:get_binary_value(<<"Callee-ID-Number">>, JObj),

    case ecallmgr_quickroute_listener:get_quickroute([RequestUser, ToUser, CalleeNumber]) of
        'undefined' -> Map;
        QuickRoute ->
            lager:notice("using a quickroute: ~p", [QuickRoute]),
            Map#{reply => #{payload => QuickRoute}}
    end.

-spec should_block_anonymous(kz_json:object()) -> boolean().
should_block_anonymous(JObj) ->
    kz_privacy:should_block_anonymous(JObj)
        orelse (kz_privacy:is_anonymous(JObj)
                andalso kz_json:is_true(<<"should_block_anonymous">>, get_blacklist(JObj))
               ).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec is_blacklisted(kz_json:object()) -> boolean().
is_blacklisted(JObj) ->
    is_number_blacklisted(get_blacklist(JObj), JObj).

-spec is_number_blacklisted(kz_json:object(), kz_json:object()) -> boolean().
is_number_blacklisted(Blacklist, JObj) ->
    Number = kz_json:get_value(<<"Caller-ID-Number">>, JObj, kz_privacy:anonymous_caller_id_number()),
    Normalized = knm_converters:normalize(Number),
    case kz_json:get_value(Normalized, Blacklist) of
        'undefined' -> 'false';
        _ -> lager:info("~s(~s) is blacklisted", [Number, Normalized]),
             'true'
    end.

-spec get_blacklists(kz_term:ne_binary()) -> kz_term:ne_binaries().
get_blacklists(AccountId) ->
    case kzd_accounts:fetch(AccountId) of
        {'error', _R} ->
            lager:error("could not open account doc ~s : ~p", [AccountId, _R]),
            [];
        {'ok', Doc} ->
            kzd_accounts:blacklists(Doc, [])
    end.

-spec get_blacklist(kz_json:object()) -> kz_json:object().
get_blacklist(JObj) ->
    AccountId = kzd_fetch:account_id(JObj),
    get_blacklist(AccountId, get_blacklists(AccountId)).

-spec get_blacklist(kz_term:ne_binary(), kz_term:ne_binaries()) -> kz_json:object().
get_blacklist(_AccountId, []) -> kz_json:new();
get_blacklist(AccountId, Blacklists) ->
    AccountDb = kzs_util:format_account_db(AccountId),
    lists:foldl(fun(BlacklistId, Acc) ->
                        case kz_datamgr:open_cache_doc(AccountDb, BlacklistId) of
                            {'error', _R} ->
                                lager:error("could not open ~s in ~s: ~p", [BlacklistId, AccountDb, _R]),
                                Acc;
                            {'ok', Doc} ->
                                Numbers = kz_json:get_value(<<"numbers">>, Doc, kz_json:new()),
                                BlackList = maybe_set_block_anonymous(Numbers, kz_json:is_true(<<"should_block_anonymous">>, Doc)),
                                kz_json:merge_jobjs(Acc, BlackList)
                        end
                end
               ,kz_json:new()
               ,Blacklists
               ).

-spec maybe_set_block_anonymous(kz_json:object(), boolean()) -> kz_json:object().
maybe_set_block_anonymous(JObj, 'false') -> JObj;
maybe_set_block_anonymous(JObj, 'true') ->
    kz_json:set_value(<<"should_block_anonymous">>, 'true', JObj).

-spec apply_formatters(dialplan_context()) -> dialplan_context().
apply_formatters(#{request := JObj}=Map) ->
    case kzd_fetch:formatters(JObj) of
        'undefined' -> Map;
        Formatters -> apply_formatters(Formatters, Map)
    end.

-spec apply_formatters(kz_json:object(), dialplan_context()) -> dialplan_context().
apply_formatters(Formatters, #{request := JObj}=Map) ->
    Map#{request => kz_formatters:apply(JObj, Formatters, 'inbound')}.
