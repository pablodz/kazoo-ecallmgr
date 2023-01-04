%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc Directory lookups from FS
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fetch_configuration_prompt).

-export([fetch_prompt/1]).
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
    _ = kazoo_bindings:bind(<<"fetch.configuration.prompt.community.general.#">>, ?MODULE, 'fetch_prompt'),
    'ok'.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec fetch_prompt(map()) -> fs_handlecall_ret().
fetch_prompt(#{node := Node, fetch_id := FetchId, payload := JObj}=Ctx) ->
    kz_log:put_callid(FetchId),
    Media = kzd_fetch:fetch_key_value(JObj),
    lager:debug("received prompt request ~s from ~s for ~s", [FetchId, Node, Media]),
    case ecallmgr_util:lookup_media(Media, 'new', kz_log:get_callid(), kz_json:new()) of
        {'error', _E} ->
            lager:warning("failed to get media path for ~s: ~p", [Media, _E]),
            prompt_not_found(Ctx);
        {'ok', Path} ->
            lager:debug("found path ~s for prompt ~s", [Path, Media]),
            {'ok', Xml} = ecallmgr_fs_xml:prompt_resp_xml(Path, JObj),
            lager:debug("sending prompt location (~s/~s) XML to ~w", [Media, Path, Node]),
            freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Xml)})
    end.

-spec prompt_not_found(map()) -> fs_handlecall_ret().
prompt_not_found(#{node := Node, payload := JObj} = Ctx) ->
    {'ok', Xml} = ecallmgr_fs_xml:not_found(),
    lager:debug("sending prompt (~s) not found XML to ~w", [kzd_fetch:fetch_key_value(JObj), Node]),
    freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Xml)}).
