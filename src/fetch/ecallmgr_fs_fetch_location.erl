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
fetch_location(#{node := Node, fetch_id := FetchId, payload := JObj}=Ctx) ->
    kz_log:put_callid(FetchId),
    lager:debug("received directory location ~s fetch request from ~s", [kzd_fetch:fetch_action(JObj), Node]),
    case kzd_fetch:fetch_action(JObj) of
        <<"call">> -> fetch_registrar(Ctx, endpoint(JObj));
        _Other -> lager:debug("unhandled action '~s' in fetch location", [_Other]),
                  location_not_found(Ctx)
    end.

-spec endpoint(kz_json:object()) -> tuple().
endpoint(JObj) ->
    EndpointId = kzd_fetch:fetch_key_value(JObj),
    Args = binary:split(EndpointId, <<"@">>),
    list_to_tuple(Args).

-spec location_not_found(map()) -> fs_handlecall_ret().
location_not_found(#{node := Node, payload := JObj} = Ctx) ->
    {'ok', Xml} = ecallmgr_fs_xml:not_found(),
    lager:debug("sending directory location (~s) not found XML to ~w", [kzd_fetch:fetch_key_value(JObj), Node]),
    freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Xml)}).

-spec fetch_registrar(map(), tuple()) -> fs_handlecall_ret().
fetch_registrar(#{node := Node, payload := JObj}=Ctx, {EndpointId, AccountId}) ->
    case ecallmgr_registrar:lookup_proxy_path(AccountId, EndpointId) of
        {error, not_found} ->
            location_not_found(Ctx);
        {ok, undefined, _Props} ->
            location_not_found(Ctx);
        {ok, Proxy, Props} ->
            {'ok', Xml} = ecallmgr_fs_xml:directory_resp_location_xml(Proxy, Props, JObj),
            lager:debug("sending directory location (~s/~s) XML to ~w", [EndpointId, AccountId, Node]),
            freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Xml)})
    end;
fetch_registrar(#{node := Node, payload := JObj}=Ctx, _) ->
    lager:debug("location format not expected from ~s => ~p", [Node, kzd_fetch:fetch_key_value(JObj)]),
    location_not_found(Ctx).
