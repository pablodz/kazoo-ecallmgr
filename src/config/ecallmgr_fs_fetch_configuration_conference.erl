%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2023, 2600Hz
%%% @doc Send conference config commands to FS
%%%
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fetch_configuration_conference).

%% API
-export([init/0]).

-export([conference/1]).

-include("ecallmgr.hrl").


%%%=============================================================================
%%% API
%%%=============================================================================


%%------------------------------------------------------------------------------
%% @doc Initializes the bindings
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"fetch.configuration.configuration.*.*.conference.conf">>, ?MODULE, 'conference'),
    'ok'.

-spec conference(map()) -> fs_sendmsg_ret().
conference(#{node := Node, fetch_id := Id, payload := JObj}=Ctx) ->
    kz_log:put_callid(Id),
    fetch_conference_config(Node, kz_api:event_name(JObj), JObj, Ctx).

-spec fetch_conference_config(atom(), kz_term:ne_binary(), kz_json:object(), map()) -> fs_sendmsg_ret().
fetch_conference_config(Node, <<"COMMAND">>, JObj, Ctx) ->
    Profile = kz_json:get_ne_binary_value([<<"Conference-Config-Request">>, <<"Profile-ID">>], JObj),
    Conference = kz_json:get_ne_binary_value([<<"Conference-Config-Request">>, <<"Conference-ID">>], JObj),
    AccountId = kzd_fetch:account_id(JObj),
    maybe_fetch_conference_profile(Node, Profile, Conference, AccountId, Ctx);
fetch_conference_config(Node, <<"REQUEST_PARAMS">>, JObj, Ctx) ->
    Action = kz_json:get_ne_binary_value([<<"Conference-Config-Request">>, <<"Action">>], JObj),
    ConfName = kz_json:get_ne_binary_value([<<"Conference-Config-Request">>, <<"Conference-ID">>], JObj),
    lager:debug("request conference:~p params:~p", [ConfName, Action]),
    fetch_conference_params(Node, Action, ConfName, JObj, Ctx).

fetch_conference_params(Node, <<"request-controls">>, ConfName, JObj, Ctx) ->
    Controls = kz_json:get_ne_binary_value([<<"Conference-Config-Request">>, <<"Controls">>], JObj),
    Profile = kz_json:get_ne_binary_value([<<"Conference-Config-Request">>, <<"Profile-ID">>], JObj),
    lager:debug("request controls:~p for profile: ~p", [Controls, Profile]),

    Cmd = [{<<"Request">>, <<"Controls">>}
          ,{<<"Profile">>, Profile}
          ,{<<"Conference-ID">>, ConfName}
          ,{<<"Controls">>, Controls}
          ,{<<"Call-ID">>, kzd_fetch:call_id(JObj)}
          ,{<<"Account-ID">>, kzd_fetch:account_id(JObj)}
          | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    Resp = kz_amqp_worker:call(Cmd
                              ,fun kapi_conference:publish_config_req/1
                              ,fun kapi_conference:config_resp_v/1
                              ,ecallmgr_fs_node:fetch_timeout(Node)
                              ),
    {'ok', Xml} = handle_conference_params_response(Resp),
    send_conference_profile_xml(Xml, Ctx);
fetch_conference_params(_Node, Action, ConfName, _Data, Ctx) ->
    lager:debug("undefined request_params action:~p conference:~p", [Action, ConfName]),
    {'ok', XmlResp} = ecallmgr_fs_xml:not_found(),
    send_conference_profile_xml(XmlResp, Ctx).

handle_conference_params_response({'ok', Resp}) ->
    lager:debug("replying with xml response for conference params request"),
    ecallmgr_fs_xml:conference_resp_xml(Resp);
handle_conference_params_response({'error', 'timeout'}) ->
    lager:debug("timed out waiting for conference params"),
    ecallmgr_fs_xml:not_found();
handle_conference_params_response(_Error) ->
    lager:debug("failed to lookup conference params, error:~p", [_Error]),
    ecallmgr_fs_xml:not_found().

-spec maybe_fetch_conference_profile(atom(), kz_term:api_binary(), kz_term:api_binary(), kz_term:api_binary(), map()) ->
          fs_sendmsg_ret().
maybe_fetch_conference_profile(_Node, _, _, 'undefined', Ctx) ->
    lager:debug("failed to lookup conference profile for undefined account-id"),
    {'ok', XmlResp} = ecallmgr_fs_xml:not_found(),
    send_conference_profile_xml(XmlResp, Ctx);

maybe_fetch_conference_profile(_Node, 'undefined', _Conference, _AccountId, Ctx) ->
    lager:debug("failed to lookup undefined profile conference"),
    {'ok', XmlResp} = ecallmgr_fs_xml:not_found(),
    send_conference_profile_xml(XmlResp, Ctx);

maybe_fetch_conference_profile(Node, Profile, Conference, AccountId, Ctx) ->
    fetch_conference_profile(Node, Profile, Conference, AccountId, Ctx).

-spec fetch_conference_profile(atom(), kz_term:api_binary(), kz_term:api_binary(), kz_term:api_binary(), map()) ->
          fs_sendmsg_ret().
fetch_conference_profile(Node, Profile, Conference, AccountId, Ctx) ->
    Cmd = [{<<"Request">>, <<"Conference">>}
          ,{<<"Profile">>, Profile}
          ,{<<"Conference-ID">>, Conference}
          ,{<<"Account-ID">>, AccountId}
          | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    lager:debug("fetching profile '~s' for conference '~s' in account '~s'", [Profile, Conference, AccountId]),
    XmlResp = case kz_amqp_worker:call(Cmd
                                      ,fun kapi_conference:publish_config_req/1
                                      ,fun kapi_conference:config_resp_v/1
                                      ,ecallmgr_fs_node:fetch_timeout(Node)
                                      )
              of
                  {'ok', Resp} ->
                      Variables = [{<<"Conference-Account-ID">>, AccountId}
                                  ,{<<"Conference-Node">>, kz_term:to_binary(node())}
                                  ,{<<"Conference-Profile">>, Profile}
                                  ],
                      Key = [<<"Profiles">>, Profile, <<"conference-variables">>],
                      VarsObj = kz_json:set_value(Key, kz_json:from_list(Variables), kz_json:new()),
                      {'ok', Xml} = ecallmgr_fs_xml:conference_resp_xml(kz_json:merge(Resp, VarsObj)),
                      lager:debug("replying with conference profile ~s", [Profile]),
                      Xml;
                  {'error', 'timeout'} ->
                      lager:debug("timed out waiting for conference profile for ~s", [Profile]),
                      {'ok', Resp} = ecallmgr_fs_xml:not_found(),
                      Resp;
                  _Other ->
                      lager:debug("failed to lookup conference profile for ~s: ~p", [Profile, _Other]),
                      {'ok', Resp} = ecallmgr_fs_xml:not_found(),
                      Resp
              end,
    send_conference_profile_xml(XmlResp, Ctx).

-spec send_conference_profile_xml(iolist(), map()) -> fs_sendmsg_ret().
send_conference_profile_xml(XmlResp, #{node := Node} = Ctx) ->
    lager:debug("sending conference profile XML to ~s: ~s", [Node, XmlResp]),
    freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(XmlResp)}).
