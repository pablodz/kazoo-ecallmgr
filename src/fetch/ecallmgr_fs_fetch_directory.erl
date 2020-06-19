%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2020, 2600Hz
%%% @doc Directory lookups from FS
%%%
%%% @author James Aimonetti
%%% @author Karl Anderson
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fetch_directory).

-export([fetch_directory/1]).
-export([init/0]).

-include("ecallmgr.hrl").

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"fetch.directory.#">>, ?MODULE, 'fetch_directory'),
    'ok'.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec fetch_directory(map()) -> fs_handlecall_ret().
fetch_directory(#{node := Node, fetch_id := FetchId, payload := JObj}=Ctx) ->
    kz_log:put_callid(FetchId),
    lager:debug("received fetch request (~s) user directory from ~s", [FetchId, Node]),
    case kzd_fetch:fetch_action(JObj, <<"sip_auth">>) of
        <<"reverse-auth-lookup">> -> lookup_user(Node, FetchId, <<"reverse-lookup">>, JObj, Ctx);
        <<"sip_auth">> -> lookup_directory(Ctx);
        <<"jsonrpc-authenticate">> -> validate_token(Ctx);
        <<"user_call">> -> lookup_directory(kzd_fetch:fetch_user(JObj), Ctx);
        <<"group_call">> -> lookup_directory(kzd_fetch:fetch_group(JObj), Ctx);
        _Other -> lager:debug("unhandled action '~s' in fetch directory", [_Other]),
                  directory_not_found(Ctx)
    end.

-spec lookup_directory(map()) -> fs_handlecall_ret().
lookup_directory(#{payload := JObj} = Ctx) ->
    lookup_directory(kzd_fetch:fetch_user(JObj), kzd_fetch:fetch_key_value(JObj), Ctx).

-spec lookup_directory(kz_term:ne_binary(), map()) -> fs_handlecall_ret().
lookup_directory(EndpointId, #{payload := JObj} = Ctx) ->
    lookup_directory(EndpointId, kzd_fetch:fetch_key_value(JObj), Ctx).

-spec lookup_directory(kz_term:api_ne_binary(), kz_term:api_ne_binary(), map()) -> fs_handlecall_ret().
lookup_directory(undefined, _AccountId, Ctx) ->
    directory_not_found(Ctx);
lookup_directory(_EndpointId, undefined, Ctx) ->
    directory_not_found(Ctx);
lookup_directory(EndpointId, ?MATCH_ACCOUNT_RAW(AccountId), #{payload := JObj} = Ctx) ->
    Opts = [{fetch_type, kzd_fetch:fetch_action(JObj, <<"sip_auth">>)}
           ,{kcid_type, kz_json:get_ne_binary_value(<<"KCID-Type">>, JObj, <<"Internal">>)}
           ,{cshs, kzd_fetch:cshs(JObj)}
           ,{ccvs, kzd_fetch:ccvs(JObj)}
           ,{cauth, kzd_fetch:cauth(JObj)}
           ],
    lager:debug("fetch directory for ~s : ~s", [EndpointId, AccountId]),
    case kz_directory:lookup(EndpointId, AccountId, Opts) of
        {ok, Endpoint} ->
            lager:debug("building directory resp for ~s@~s from endpoint", [EndpointId, AccountId]),
            {'ok', Xml} = ecallmgr_fs_xml:directory_resp_endpoint_xml(Endpoint, JObj),
            freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Xml)});
        {error, _Err} ->
            lager:debug("error getting profile for for ~s@~s from endpoint : ~p", [EndpointId, AccountId, _Err]),
            directory_not_found(Ctx)
    end;
lookup_directory(_EndpointId, _Realm, Ctx) ->
    directory_not_found(Ctx).

-spec directory_not_found(map()) -> fs_handlecall_ret().
directory_not_found(#{node := Node} = Ctx) ->
    {'ok', Xml} = ecallmgr_fs_xml:not_found(),
    lager:debug("sending directory not found XML to ~w", [Node]),
    freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Xml)}).

-spec lookup_user(atom(), kz_term:ne_binary(), kz_term:ne_binary(), kz_json:object(), map()) -> fs_handlecall_ret().
lookup_user(Node, Id, Method,  JObj, Ctx) ->
    Domain = kz_json:get_value(<<"domain">>, JObj),
    {'ok', Xml} =
        case get_auth_realm(JObj) of
            AuthRealm=?NE_BINARY ->
                [Realm|_] = binary:split(AuthRealm, [<<":">>, <<";">>]),
                Username = kz_json:get_first_defined([<<"user">>, <<"Auth-User">>], JObj),
                ReqResp = maybe_query_registrar(Realm, Username, Node, Id, Method, JObj),
                handle_lookup_resp(Method, Domain, Username, ReqResp);
            _R ->
                lager:error_unsafe("bad auth realm: ~p : ~s", [_R, kz_json:encode(JObj, ['pretty'])]),
                ecallmgr_fs_xml:not_found()
        end,
    lager:debug("sending authn XML to ~w: ~s", [Node, Xml]),
    freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Xml)}).

-spec get_auth_realm(kz_json:object()) -> kz_term:ne_binary().
get_auth_realm(JObj) ->
    case kz_json:get_first_defined([<<"sip_auth_realm">>
                                   ,<<"domain">>
                                   ], JObj)
    of
        'undefined' -> get_auth_uri_realm(JObj);
        Realm ->
            case kz_network_utils:is_ipv4(Realm)
                orelse kz_network_utils:is_ipv6(Realm)
            of
                'true' -> get_auth_uri_realm(JObj);
                'false' -> kz_term:to_lower_binary(Realm)
            end
    end.

-spec get_auth_uri_realm(kz_json:object()) -> kz_term:ne_binary().
get_auth_uri_realm(JObj) ->
    AuthURI = kz_json:get_value(<<"sip_auth_uri">>, JObj, <<>>),
    case binary:split(AuthURI, <<"@">>) of
        [_, Realm] -> kz_term:to_lower_binary(Realm);
        _Else ->
            kz_json:get_first_defined([<<"Auth-Realm">>
                                      ,<<"sip_request_host">>
                                      ,<<"sip_to_host">>
                                      ], JObj)
    end.

-spec handle_lookup_resp(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()
                        ,{'ok', kz_json:object()} | {'error', _}) ->
          {'ok', _}.
handle_lookup_resp(<<"reverse-lookup">>, Realm, Username, {'ok', JObj}) ->
    Props = [{<<"Domain-Name">>, Realm}
            ,{<<"User-ID">>, Username}
            ],
    lager:debug("building reverse authn resp for ~s@~s", [Username, Realm]),
    ecallmgr_fs_xml:reverse_authn_resp_xml(kz_json:set_values(Props, JObj));
handle_lookup_resp(_, Realm, Username, {'ok', JObj}) ->
    Props = [{<<"Domain-Name">>, Realm}
            ,{<<"User-ID">>, Username}
            ,{<<"Expires">>, 0}
            ],
    lager:debug("building authn resp for ~s@~s", [Username, Realm]),
    ecallmgr_fs_xml:authn_resp_xml(kz_json:set_values(Props, JObj));
handle_lookup_resp(_, _, _, {'error', _R}) ->
    lager:debug("authn request lookup failed: ~p", [_R]),
    ecallmgr_fs_xml:not_found().

-spec maybe_query_registrar(kz_term:ne_binary(), kz_term:ne_binary(), atom(), kz_term:ne_binary(), kz_term:ne_binary(), kz_json:object()) ->
          {'ok', kz_json:object()} |
          {'error', any()}.
maybe_query_registrar(Realm, Username, Node, Id, Method, JObj) ->
    case kz_cache:peek_local(?ECALLMGR_AUTH_CACHE, ?CREDS_KEY(Realm, Username)) of
        {'ok', _}=Ok -> Ok;
        {'error', 'not_found'} -> query_registrar(Realm, Username, Node, Id, Method, JObj)
    end.

-spec query_registrar(kz_term:ne_binary(), kz_term:ne_binary(), atom(), kz_term:ne_binary(), kz_term:ne_binary(), kz_json:object()) ->
          {'ok', kz_json:object()} |
          {'error', any()}.
query_registrar(Realm, Username, Node, Id, Method, JObj) ->
    lager:debug("looking up credentials of ~s@~s for a ~s", [Username, Realm, Method]),
    Req = [{<<"Msg-ID">>, Id}
          ,{<<"To">>, <<Username/binary, "@", Realm/binary>>}
          ,{<<"From">>, <<Username/binary, "@", Realm/binary>>}
          ,{<<"Orig-IP">>, kzd_fetch:from_network_ip(JObj)}
          ,{<<"Orig-Port">>, kzd_fetch:from_network_port(JObj)}
          ,{<<"Method">>, Method}
          ,{<<"Auth-User">>, Username}
          ,{<<"Auth-Realm">>, Realm}
          ,{<<"Expires">>, kzd_fetch:auth_expires(JObj)}
          ,{<<"Auth-Nonce">>, kzd_fetch:auth_nonce(JObj)}
          ,{<<"Auth-Response">>, kzd_fetch:auth_response(JObj)}
          ,{<<"Custom-SIP-Headers">>, kzd_fetch:ccvs(JObj)}
          ,{<<"User-Agent">>, kzd_fetch:user_agent(JObj)}
          ,{<<"Media-Server">>, kz_term:to_binary(Node)}
          ,{<<"Call-ID">>, kzd_fetch:call_id(JObj)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    ReqResp = kz_amqp_worker:call(props:filter_undefined(Req)
                                 ,fun kapi_authn:publish_req/1
                                 ,fun kapi_authn:resp_v/1
                                 ),
    case ReqResp of
        {'error', _}=E -> E;
        {'ok', Resp} -> maybe_defered_error(Realm, Username, Resp)
    end.

%% NOTE: Kamailio needs registrar errors since it is blocking with no
%%   timeout (at the moment) but when we seek auth for INVITEs we need
%%   to wait for conferences, etc.  Since Kamailio does not honor
%%   Defer-Response we can use that flag on registrar errors
%%   to queue in Kazoo but still advance Kamailio, just need to check here.
-spec maybe_defered_error(kz_term:ne_binary(), kz_term:ne_binary(), kz_json:object()) -> {'ok', kz_json:object()} | {'error', 'timeout'}.
maybe_defered_error(Realm, Username, JObj) ->
    case kapi_authn:resp_v(JObj) of
        'false' -> {'error', 'timeout'};
        'true' ->
            AccountId = kz_json:get_value([<<"Custom-Channel-Vars">>, <<"Account-ID">>], JObj),
            AccountDb = kzs_util:format_account_db(AccountId),
            AuthorizingId = kz_json:get_value([<<"Custom-Channel-Vars">>, <<"Authorizing-ID">>], JObj),
            OwnerIdProp = case kz_json:get_value([<<"Custom-Channel-Vars">>, <<"Owner-ID">>], JObj) of
                              'undefined' -> [];
                              OwnerId -> [{'db', AccountDb, OwnerId}]
                          end,
            CacheProps = [{'origin', [{'db', AccountDb, AuthorizingId}
                                     ,{'db', AccountDb, AccountId}
                                      | OwnerIdProp
                                     ]}
                         ],
            kz_cache:store_local(?ECALLMGR_AUTH_CACHE, ?CREDS_KEY(Realm, Username), JObj, CacheProps),
            {'ok', JObj}
    end.

-spec validate_token(map()) -> fs_handlecall_ret().
validate_token(#{payload := JObj}=Ctx) ->
    case kz_json:get_ne_binary_value(<<"X-Auth-Token">>, JObj) of
        undefined -> directory_not_found(Ctx);
        Token -> validate_token(Ctx, kz_auth:validate_token(Token))
    end.

-type validate_token_result() :: {'ok', kz_json:object()} | {'error', any()}.

-spec validate_token(map(), validate_token_result()) -> fs_handlecall_ret().
validate_token(Ctx, {error, Error}) ->
    lager:warning("invalid token : ~s", [Error]),
    directory_not_found(Ctx);
validate_token(#{payload := JObj} = Ctx, {ok, Claims}) ->
    lager:debug("token => ~s", [kz_json:encode(Claims, [pretty])]),
    AccountId = kz_json:get_ne_binary_value(<<"account_id">>, Claims),
    OwnerId = kz_json:get_ne_binary_value(<<"owner_id">>, Claims),
    KVs = [{<<"Requested-Domain-Name">>, kzd_fetch:fetch_key_value(JObj)}
          ,{<<"Requested-User-ID">>, kzd_fetch:fetch_user(JObj)}
          ],
    lookup_directory(OwnerId, AccountId, Ctx#{payload => kz_json:set_values(KVs, JObj)}).
