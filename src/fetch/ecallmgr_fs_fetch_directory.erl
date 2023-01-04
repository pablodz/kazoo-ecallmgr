%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
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
    _ = kazoo_bindings:bind(<<"fetch.directory.domain.#">>, ?MODULE, 'fetch_directory'),
    'ok'.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec fetch_directory(map()) -> fs_handlecall_ret().
fetch_directory(#{fetch_id := FetchId, payload := JObj}=Context) ->
    kz_log:put_callid(JObj),
    FetchAction = kzd_fetch:fetch_action(JObj, <<"sip_auth">>),
    log_directory_fetch(FetchAction, Context),
    case FetchAction of
        <<"sip_auth">> -> lookup_directory(Context);
        <<"sip_auth_token">> -> validate_token(Context);
        <<"jsonrpc-authenticate">> -> validate_rpc_token(Context);
        <<"user_call">> -> lookup_registrar(Context);
        <<"group_call">> -> lookup_directory(kzd_fetch:fetch_group(JObj), Context);
        <<"reverse-auth-lookup">> -> reverse_auth(Context);
        _Other ->
            lager:error_unsafe("unhandled action '~s' in request ~s => ~s", [_Other, FetchId, kz_json:encode(JObj)]),
            directory_not_found(Context)
    end.

-spec log_directory_fetch(kz_term:ne_binary(), map()) -> 'ok'.
log_directory_fetch(FetchAction, #{node := Node, fetch_id := FetchId} = Context) ->
    lager:info("received ~s fetch from ~s for request ~s"
              ,[FetchAction, Node, FetchId]
              ),
    log_directory_cauth_details(FetchAction, Context).

-spec log_directory_cauth_details(kz_term:ne_binary(), map()) -> 'ok'.
log_directory_cauth_details(FetchAction, #{fetch_id := FetchId} = Context) ->
    Routines = [fun maybe_log_directory_cauth_ip/2
               ,fun maybe_log_directory_cauth_port/2
               ,fun maybe_log_directory_cauth_from_user/2
               ,fun maybe_log_directory_cauth_uri/2
               ,fun maybe_log_directory_cauth_token/2
               ],
    Log = lists:foldl(fun(F, Log) ->
                              case F(FetchAction, Context) of
                                  'undefined' -> Log;
                                  Details -> <<Log/binary, Details/binary>>
                              end
                      end
                     ,<<>>
                     ,Routines
                     ),
    case kz_term:is_empty(Log) of
        'true' -> 'ok';
        'false' ->
            lager:debug("authorization~s for request ~s~n"
                       ,[Log, FetchId]
                       )
    end.

-spec maybe_log_directory_cauth_ip(kz_term:ne_binary(), map()) -> kz_term:api_ne_binary().
maybe_log_directory_cauth_ip(_FetchAction, #{payload := JObj}) ->
    case kz_json:get_ne_binary_value(<<"IP">>, kzd_fetch:cauth(JObj)) of
        'undefined' -> 'undefined';
        IP -> <<" ip ", IP/binary>>
    end.

-spec maybe_log_directory_cauth_port(kz_term:ne_binary(), map()) -> kz_term:api_ne_binary().
maybe_log_directory_cauth_port(_FetchAction, #{payload := JObj}) ->
    case kz_json:get_ne_binary_value(<<"PORT">>, kzd_fetch:cauth(JObj)) of
        'undefined' -> 'undefined';
        Port -> <<":", Port/binary>>
    end.

-spec maybe_log_directory_cauth_from_user(kz_term:ne_binary(), map()) -> kz_term:api_ne_binary().
maybe_log_directory_cauth_from_user(_FetchAction, #{payload := JObj}) ->
    case kz_json:get_ne_binary_value(<<"From-User">>, kzd_fetch:cauth(JObj)) of
        'undefined' -> 'undefined';
        User -> <<" from ", User/binary>>
    end.

-spec maybe_log_directory_cauth_uri(kz_term:ne_binary(), map()) -> kz_term:api_ne_binary().
maybe_log_directory_cauth_uri(_FetchAction, #{payload := JObj}) ->
    CAuth = kzd_fetch:cauth(JObj),
    User = kz_json:get_ne_binary_value(<<"URI-User">>, CAuth),
    Realm = kz_json:get_ne_binary_value(<<"URI-Realm">>, CAuth),
    case {User, Realm} of
        {'undefined', 'undefined'} -> 'undefined';
        {'undefined', Realm} -> <<" to ", Realm/binary>>;
        {User, 'undefined'} -> <<" to ", User/binary>>;
        {User, Realm} -> <<" to ", User/binary, "@", Realm/binary>>
    end.

-spec maybe_log_directory_cauth_token(kz_term:ne_binary(), map()) -> kz_term:api_ne_binary().
maybe_log_directory_cauth_token(_FetchAction, #{payload := JObj}) ->
    case kz_json:get_ne_binary_value(<<"Token">>, kzd_fetch:cauth(JObj)) of
        'undefined' -> 'undefined';
        Token -> <<" with token ", Token/binary>>
    end.

-spec lookup_directory(map()) -> fs_handlecall_ret().
lookup_directory(#{payload := JObj} = Context) ->
    lookup_directory(kzd_fetch:fetch_user(JObj), kzd_fetch:fetch_key_value(JObj), Context).

-spec lookup_directory(kz_term:ne_binary(), map()) -> fs_handlecall_ret().
lookup_directory(EndpointId, #{payload := JObj} = Context) ->
    lookup_directory(EndpointId, kzd_fetch:fetch_key_value(JObj), Context).

-spec lookup_directory(kz_term:api_ne_binary(), kz_term:api_ne_binary(), map()) -> fs_handlecall_ret().
lookup_directory('undefined', _AccountId, #{fetch_id := FetchId} = Context) ->
    lager:info("directory lookup unable to progress because the endpoint id is not present for request ~s"
              ,[FetchId]
              ),
    directory_not_found(Context);
lookup_directory(_EndpointId, 'undefined', #{fetch_id := FetchId} = Context) ->
    lager:info("directory lookup unable to progress because the account id is not present for request ~s"
              ,[FetchId]
              ),
    directory_not_found(Context);
lookup_directory(EndpointId, ?MATCH_ACCOUNT_RAW(AccountId), Context) ->
    fetch_directory(EndpointId, AccountId, Context);
lookup_directory(_EndpointId, _AccountId, #{fetch_id := FetchId} = Context) ->
    lager:info("directory lookup unable to progress because the account id ~s is not a 32 byte UUID for request ~s"
              ,[_AccountId, FetchId]
              ),
    directory_not_found(Context).

-spec directory_not_found(map()) -> fs_handlecall_ret().
directory_not_found(#{node := Node, fetch_id := FetchId} = Context) ->
    {'ok', Xml} = ecallmgr_fs_xml:not_found(<<"directory">>),
    lager:warning("sending directory not found to ~w as reply for request ~s"
                 ,[Node, FetchId]
                 ),
    freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Xml)}).

-spec validate_token(map()) -> fs_handlecall_ret().
validate_token(#{fetch_id := FetchId, payload := JObj}=Context) ->
    case kz_json:get_ne_binary_value(<<"JWT-Token">>, kzd_fetch:cauth(JObj)) of
        'undefined' ->
            lager:info("directory lookup unable to progress because the JWT token was not present on request ~s"
                      ,[FetchId]
                      ),
            directory_not_found(Context);
        Token -> validate_token(Context#{auth_token => Token}, kz_auth:validate_token(Token))
    end.

-type validate_token_result() :: {'ok', kz_json:object()} | {'error', any()}.

-spec validate_token(map(), validate_token_result()) -> fs_handlecall_ret().
validate_token(#{fetch_id := FetchId}=Context, {'error', Error}) ->
    lager:info("fetch request ~s has an invalid token: ~s"
              ,[FetchId, Error]
              ),
    directory_not_found(Context);
validate_token(#{payload := JObj, auth_token := Token} = Context, {'ok', Claims}) ->
    Sub = kz_json:get_ne_binary_value(<<"sub">>, Claims),
    [EndpointId, AccountId] = binary:split(Sub, <<"@">>, ['global']),
    KVs = [{<<"Requested-Domain-Name">>, kzd_fetch:fetch_key_value(JObj)}
          ,{<<"Requested-User-ID">>, kzd_fetch:fetch_user(JObj)}
          ],
    Ctx = Context#{payload => kz_json:set_values(KVs, JObj)
                  ,endpoint_id => EndpointId
                  ,account_id => AccountId
                  },
    Options = [{'token', Token}],
    fetch_directory(EndpointId, AccountId, Ctx, Options).

-spec validate_rpc_token(map()) -> fs_handlecall_ret().
validate_rpc_token(#{fetch_id := FetchId, payload := JObj}=Context) ->
    case kz_json:get_ne_binary_value(<<"Token">>, kzd_fetch:cauth(JObj)) of
        'undefined' ->
            lager:info("directory lookup unable to progress because the RPC token was invalid on request ~s"
                      ,[FetchId]
                      ),
            directory_not_found(Context);
        Token -> validate_rpc_token(Context, kz_auth:validate_token(Token))
    end.

-type validate_rpc_token_result() :: {'ok', kz_json:object()} | {'error', any()}.

-spec validate_rpc_token(map(), validate_rpc_token_result()) -> fs_handlecall_ret().
validate_rpc_token(#{fetch_id := FetchId}=Context, {'error', Error}) ->
    lager:info("fetch request ~s has an invalid token: ~p"
              ,[FetchId, Error]
              ),
    directory_not_found(Context);
validate_rpc_token(#{payload := JObj} = Context, {'ok', Claims}) ->
    AccountId = kz_json:get_ne_binary_value(<<"account_id">>, Claims),
    OwnerId = kz_json:get_ne_binary_value(<<"owner_id">>, Claims),
    KVs = [{<<"Requested-Domain-Name">>, kzd_fetch:fetch_key_value(JObj)}
          ,{<<"Requested-User-ID">>, kzd_fetch:fetch_user(JObj)}
          ],
    lookup_directory(OwnerId, AccountId, Context#{payload => kz_json:set_values(KVs, JObj)}).

-spec fetch_direction(kz_json:object()) -> kz_term:ne_binary().
fetch_direction(JObj) ->
    case kzd_fetch:fetch_action(JObj) of
        <<"user_call">> -> <<"outbound">>;
        _ -> <<"inbound">>
    end.

-spec fetch_options(map()) -> kz_term:proplist().
fetch_options(#{payload := JObj}) ->
    [{'fetch_type', kzd_fetch:fetch_action(JObj, <<"sip_auth">>)}
    ,{'kcid_type', kz_json:get_ne_binary_value(<<"KCID-Type">>, JObj, <<"Internal">>)}
    ,{'cshs', kzd_fetch:cshs(JObj)}
    ,{'ccvs', kzd_fetch:ccvs(JObj)}
    ,{'cauth', kzd_fetch:cauth(JObj)}
    ,{'direction', fetch_direction(JObj)}
    ].

fetch_directory(EndpointId, AccountId, Context) ->
    fetch_directory(EndpointId, AccountId, Context, []).

fetch_directory(EndpointId, AccountId, #{payload := JObj, node := Node, fetch_id := FetchId} = Context, Options) ->
    Opts = props:set_values(Options, fetch_options(Context)),
    case kz_directory:lookup(EndpointId, AccountId, Opts) of
        {'ok', Endpoint} ->
            lager:debug("found profile ~s@~s for request ~s"
                       ,[EndpointId, AccountId, FetchId]
                       ),
            {'ok', Xml} = ecallmgr_fs_xml:directory_resp_endpoint_xml(Node, Endpoint, JObj),
            send_reply(Context#{reply => iolist_to_binary(Xml)});
        {'error', _Err} ->
            lager:notice("unable to get profile ~s@~s for request ~s: ~p"
                        ,[EndpointId, AccountId, FetchId, _Err]
                        ),
            directory_not_found(Context)
    end.

send_reply(#{node := Node, fetch_id := FetchId} = Context) ->
    lager:debug("sending directory fetch reply to ~w for request ~s"
               ,[Node, FetchId]
               ),
    freeswitch:fetch_reply(Context).

-spec lookup_registrar(map()) -> fs_handlecall_ret().
lookup_registrar(#{payload := JObj}=Context) ->
    EndpointId = kzd_fetch:fetch_user(JObj),
    AccountId = kzd_fetch:fetch_key_value(JObj),
    KVs = [{<<"Requested-User-ID">>, EndpointId}
          ,{<<"Requested-Domain-Name">>, AccountId}
          ],
    lookup_registrar(Context#{payload => kz_json:set_values(KVs, JObj)}
                    ,EndpointId
                    ,AccountId
                    ).

lookup_registrar(#{fetch_id := FetchId} = Context, EndpointId, AccountId) ->
    case ecallmgr_registrar:lookup_endpoint(EndpointId, AccountId) of
        {'error', 'not_found'} ->
            lager:info("unable to find registration ~s@~s for request ~s"
                      ,[EndpointId, AccountId, FetchId]
                      ),
            lookup_directory(Context);
        {'ok', Endpoint} ->
            lager:debug("found registration ~s@~s for request ~s"
                       ,[EndpointId, AccountId, FetchId]
                       ),
            fetch_directory(EndpointId, AccountId, Context, [{'endpoint', kz_json:from_list(Endpoint)}])
    end.

reverse_auth(#{payload := JObj}=Context) ->
    Username = kzd_fetch:fetch_user(JObj),
    Realm = kzd_fetch:fetch_key_value(JObj),
    Method = kzd_fetch:auth_method(JObj, <<"password">>),
    KVs = [{<<"User-ID">>, Username}
          ,{<<"Domain-Name">>, Realm}
          ,{<<"Auth-Method">>, Method}
          ,{<<"Auth-Username">>, Username}
          ],
    case kz_directory:lookup_by_user_realm(Username, Realm) of
        {'ok', Endpoint} ->
            {'ok', Xml} = ecallmgr_fs_xml:reverse_authn_resp_xml(kz_json:set_values(KVs, kz_ccv:ccvs(Endpoint))),
            send_reply(Context#{reply => iolist_to_binary(Xml)});
        _Else ->
            directory_not_found(Context)
    end.
