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
    AccountId = kz_json:get_ne_binary_value(<<"account_id">>, Claims),
    OwnerId = kz_json:get_ne_binary_value(<<"owner_id">>, Claims),
    KVs = [{<<"Requested-Domain-Name">>, kzd_fetch:fetch_key_value(JObj)}
          ,{<<"Requested-User-ID">>, kzd_fetch:fetch_user(JObj)}
          ],
    lookup_directory(OwnerId, AccountId, Ctx#{payload => kz_json:set_values(KVs, JObj)}).
