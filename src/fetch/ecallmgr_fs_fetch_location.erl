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
-module(ecallmgr_fs_fetch_location).

-export([fetch_location/1]).
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
    _ = kazoo_bindings:bind(<<"fetch.directory.location.#">>, ?MODULE, 'fetch_location'),
    'ok'.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec fetch_location(map()) -> fs_handlecall_ret().
fetch_location(#{node := Node, fetch_id := FetchId, payload := JObj}=Context) ->
    kz_log:put_callid(JObj),
    lager:debug("received location ~s fetch request ~s for ~s from ~s"
               ,[kzd_fetch:fetch_action(JObj), FetchId, kzd_fetch:fetch_key_value(JObj), Node]
               ),
    case kzd_fetch:fetch_action(JObj) of
        <<"call">> -> fetch_registration(Context, endpoint(JObj));
        _Other ->
            lager:debug("unhandled action '~s' in fetch ~s location"
                       ,[_Other, FetchId]
                       ),
            location_not_found(Context)
    end.

-spec endpoint(kz_json:object()) -> tuple().
endpoint(JObj) ->
    EndpointId = kzd_fetch:fetch_key_value(JObj),
    Args = binary:split(EndpointId, <<"@">>),
    list_to_tuple(Args).

-spec location_not_found(map()) -> fs_handlecall_ret().
location_not_found(#{fetch_id := FetchId, node := Node, payload := JObj} = Context) ->
    {'ok', Xml} = ecallmgr_fs_xml:not_found(<<"location">>),
    lager:debug("sending directory location (~s) not found XML to ~w for request ~s"
               ,[kzd_fetch:fetch_key_value(JObj), Node, FetchId]
               ),
    freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Xml)}).

-spec fetch_registration(map(), tuple()) -> fs_handlecall_ret().
fetch_registration(Context, {EndpointId, AccountId}) ->
    case kz_app_config:get_boolean(?APP, <<"use_proxy_contact_api">>, 'false') of
        'true' -> fetch_from_proxy(Context, AccountId, EndpointId);
        'false' -> fetch_from_registrar(Context, AccountId, EndpointId)
    end;
fetch_registration(#{fetch_id := FetchId, node := Node, payload := JObj}=Context, _) ->
    lager:debug("location format not expected from ~s => ~p on request ~s"
               ,[Node, kzd_fetch:fetch_key_value(JObj), FetchId]
               ),
    location_not_found(Context).

-spec fetch_from_registrar(map(), kz_term:ne_binary(), kz_term:ne_binary()) -> fs_handlecall_ret().
fetch_from_registrar(#{fetch_id := FetchId, node := Node, payload := JObj}=Context, AccountId, EndpointId) ->
    case ecallmgr_registrar:lookup_proxy_path(AccountId, EndpointId) of
        {'error', 'not_found'} ->
            location_not_found(Context);
        {'ok', 'undefined', _Props} ->
            location_not_found(Context);
        {'ok', Proxy, Props} ->
            {'ok', Xml} = ecallmgr_fs_xml:directory_resp_location_xml(Proxy, Props, JObj),
            lager:debug("sending directory location (~s/~s) XML to ~w for request ~s"
                       ,[EndpointId, AccountId, Node, FetchId]
                       ),
            freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Xml)});
        {'ok', Metas} ->
            {'ok', Xml} = ecallmgr_fs_xml:directory_resp_location_xml(Metas, JObj),
            lager:debug("sending ~B directory locations (~s/~s) XML to ~w for request ~s"
                       ,[length(Metas), EndpointId, AccountId, Node, FetchId]
                       ),
            freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Xml)})
    end.

-spec fetch_from_proxy(map(), kz_term:ne_binary(), kz_term:ne_binary()) -> fs_handlecall_ret().
fetch_from_proxy(#{fetch_id := FetchId, node := Node, payload := JObj}=Context, AccountId, EndpointId) ->
    Req = build_search_req(EndpointId, AccountId),
    case kz_amqp_worker:call(Req, fun kapi_registration:publish_search_req/1) of
        {'ok', RegObj} ->
            AOR = kz_json:get_json_value(<<"AOR">>, RegObj),
            Proxy = kz_json:get_ne_binary_value(<<"uri">>, AOR),
            Props = proxy_props(AOR),
            {'ok', Xml} = ecallmgr_fs_xml:directory_resp_location_xml(Proxy, Props, JObj),
            lager:debug("sending directory location (~s/~s) XML to ~w for request ~s"
                       ,[EndpointId, AccountId, Node, FetchId]
                       ),
            freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Xml)});
        _Else ->
            location_not_found(Context)
    end.

build_search_req(EndpointId, AccountId) ->
    [{<<"Token-ID">>, list_to_binary([EndpointId, "@", AccountId])}
    ,{<<"Search-Type">>, <<"token">>}
    | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec proxy_props(kz_json:object()) -> kz_term:proplist().
proxy_props(JObj) ->
    Funs = [fun proxy_add_aor/2
           ,fun proxy_check_protocol/2
           ],
    lists:foldl(fun(F, Acc) -> F(JObj, Acc) end, [], Funs).

-spec proxy_add_aor(kz_json:object(), kz_term:proplist()) -> kz_term:proplist().
proxy_add_aor(JObj, Props) ->
    AOR = kz_json:get_ne_binary_value(<<"aor">>, JObj),
    [{<<"SIP-Invite-To-URI">>, AOR}
    ,{<<"KAZOO-AOR">>, AOR}
    | Props
    ].

-spec proxy_check_protocol(kz_json:object(), kz_term:proplist()) -> kz_term:proplist().
proxy_check_protocol(JObj, Props) ->
    case kz_json:get_ne_binary_value(<<"Proxy-Protocol">>, JObj) of
        <<"ws", _/binary>> ->
            [{<<"Media-Webrtc">>, 'true'}
            ,{<<"RTCP-MUX">>, 'true'}
            | Props
            ];
        _Else -> Props
    end.
