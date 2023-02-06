%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2023, 2600Hz
%%% @doc Send config commands to FS
%%%
%%% @author Edouard Swiac
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fetch_configuration_sofia).

%% API
-export([init/0]).

-export([sofia/1]).

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
    _ = kazoo_bindings:bind(<<"fetch.configuration.configuration.*.*.sofia.conf">>, ?MODULE, 'sofia'),
    'ok'.

-spec sofia(map()) -> fs_sendmsg_ret().
sofia(#{fetch_id := Id} = Ctx) ->
    kz_log:put_callid(Id),
    case kapps_config:is_true(?APP_NAME, <<"sofia_conf">>, 'false') of
        'false' ->
            lager:info("sofia conf disabled"),
            {'ok', Resp} = ecallmgr_fs_xml:not_found(<<"sofia conf disabled">>),
            freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Resp)});
        'true' ->
            sofia_conf(Ctx)
    end.

sofia_conf(Ctx) ->
    Routines = [fun sofia_settings/1
               ,fun sofia_profiles/1
               ,fun sofia_reply/1
               ],
    kz_maps:exec(Routines, Ctx#{conf => kz_json:new()}).

sofia_settings(#{conf := Conf} = Ctx) ->
    Settings = kapps_config:get_json(?APP_NAME, [<<"sofia">>, <<"settings">>], kz_json:new()),
    Ctx#{conf => kz_json:set_value(<<"settings">>, Settings, Conf)}.

sofia_profiles(#{conf := Conf} = Ctx) ->
    Profiles = kapps_config:get_json(?APP_NAME, [<<"sofia">>, <<"profiles">>], kz_json:new()),
    Ctx#{conf => kz_json:set_value(<<"profiles">>, kz_json:map(sofia_profiles_map_fun(), Profiles), Conf)}.

sofia_profiles_map_fun() ->
    Default = default_sip_profile(),
    fun(K, V) ->
            {K, kz_json:merge(Default, V)}
    end.

sofia_reply(#{node := Node, conf := Conf} = Ctx) ->
    try ecallmgr_fs_xml:sofia_conf_xml(Conf) of
        {'ok', ConfigXml} ->
            lager:debug("sending sofia XML to ~s: ~s", [Node, ConfigXml]),
            freeswitch:fetch_reply(Ctx#{reply => erlang:iolist_to_binary(ConfigXml)})
    catch
        _E:_R ->
            lager:info("sofia profile resp failed to convert to XML (~s): ~p", [_E, _R]),
            {'ok', Resp} = ecallmgr_fs_xml:not_found(<<"sofia conf error">>),
            freeswitch:fetch_reply(Ctx#{reply => iolist_to_binary(Resp)})
    end.

-spec default_sip_profile() -> kz_json:object().
default_sip_profile() ->
    kz_json:from_list([{<<"Settings">>, kz_json:from_list(default_sip_settings())}]).

-spec default_sip_settings() -> kz_term:proplist().
default_sip_settings() ->
    [{<<"message-threads">>, <<"10">>}
    ,{<<"auth-calls">>, <<"true">>}
    ,{<<"apply-nat-acl">>, <<"rfc1918.auto">>}
    ,{<<"apply-inbound-acl">>, <<"trusted">>}
    ,{<<"apply-proxy-acl">>, <<"authoritative">>}
    ,{<<"local-network-acl">>, <<"localnet.auto">>}
    ,{<<"challenge-realm">>, <<"auto_from">>}
    ,{<<"multiple-registrations">>, <<"false">>}
    ,{<<"accept-blind-reg">>, <<"false">>}
    ,{<<"accept-blind-auth">>, <<"false">>}
    ,{<<"nonce-ttl">>, <<"86400">>}
    ,{<<"disable-register">>, <<"false">>}
    ,{<<"inbound-reg-force-matching-username">>, <<"true">>}
    ,{<<"auth-all-packets">>, <<"false">>}
    ,{<<"context">>, <<"context_2">>}
    ,{<<"dialplan">>, <<"XML">>}
    ,{<<"manual-redirect">>, <<"false">>}
    ,{<<"disable-transfer">>, <<"false">>}
    ,{<<"sip-ip">>, <<"$${local_ip_v4}">>}
    ,{<<"ext-sip-ip">>, <<"auto">>}
    ,{<<"sip-port">>, <<"5060">>}
    ,{<<"user-agent-string">>, <<"2600hz">>}
    ,{<<"enable-100rel">>, <<"false">>}
    ,{<<"max-proceeding">>, <<"1000">>}
    ,{<<"inbound-use-callid-as-uuid">>, <<"true">>}
    ,{<<"outbound-use-uuid-as-callid">>, <<"true">>}
    ,{<<"rtp-ip">>, <<"$${local_ip_v4}">>}
    ,{<<"ext-rtp-ip">>, <<"auto">>}
    ,{<<"rtp-timer-name">>, <<"soft">>}
    ,{<<"rtp-autoflush-during-bridge">>, <<"true">>}
    ,{<<"rtp-rewrite-timestamps">>, <<"false">>}
    ,{<<"hold-music">>, <<"local_stream://default">>}
    ,{<<"record-path">>, <<"$${recordings_dir}">>}
    ,{<<"record-template">>, <<"${caller_id_number}.${target_domain}.${strftime(%Y-%m-%d-%H-%M-%S)}.wav">>}
    ,{<<"dtmf-duration">>, <<"960">>}
    ,{<<"rfc2833-pt">>, <<"101">>}
    ,{<<"dtmf-type">>, <<"rfc2833">>}
    ,{<<"pass-rfc2833">>, <<"false">>}
    ,{<<"inbound-codec-prefs">>, <<"$${codecs}">>}
    ,{<<"outbound-codec-prefs">>, <<"$${codecs}">>}
    ,{<<"inbound-codec-negotiation">>, <<"generous">>}
    ,{<<"inbound-late-negotiation">>, <<"false">>}
    ,{<<"disable-transcoding">>, <<"false">>}
    ,{<<"t38-passthru">>, <<"true">>}
    ,{<<"all-reg-options-ping">>, <<"true">>}
    ,{<<"enable-timer">>, <<"false">>}
    ,{<<"rtp-timeout-sec">>, <<"3600">>}
    ,{<<"rtp-hold-timeout-sec">>, <<"3600">>}
    ,{<<"minimum-session-expires">>, <<"90">>}
    ,{<<"manage-presence">>, <<"true">>}
    ,{<<"send-message-query-on-register">>, <<"false">>}
    ,{<<"watchdog-enabled">>, <<"false">>}
    ,{<<"debug">>, <<"info">>}
    ,{<<"sip-trace">>, <<"true">>}
    ,{<<"log-auth-failures">>, <<"true">>}
    ,{<<"log-level">>, <<"info">>}
    ,{<<"tracelevel">>, <<"debug">>}
    ,{<<"debug-presence">>, <<"0">>}
    ,{<<"debug-sla">>, <<"0">>}
    ,{<<"auto-restart">>, <<"false">>}
    ,{<<"rtp-enable-zrtp">>, <<"true">>}
    ,{<<"liberal-dtmf">>, <<"true">>}
    ,{<<"apply-candidate-acl">>, <<"0.0.0.0/0">>}
    ,{<<"apply-inbound-acl-x-token">>, <<"X-FS-Auth-Token">>}
    ,{<<"apply-proxy-acl-x-token">>, <<"X-AUTH-Token">>}
    ,{<<"user-x-token-jwt-header">>, <<"X-AUTH-JWT-Token">>}
    ,{<<"enable-uuid-acl-check">>, <<"true">>}
    ,{<<"apply-proxy-acl-uuid-x-header">>, <<"X-Proxy-Core-UUID">>}
    ,{<<"apply-inbound-acl-uuid-x-header">>, <<"X-FS-Core-UUID">>}
    ,{<<"enable-core-uuid-header">>, <<"true">>}
    ,{<<"auth-calls">>, <<"true">>}
    ,{<<"auth-calls-acl-only">>, <<"true">>}
    ,{<<"auth-require-user">>, <<"true">>}
    ,{<<"disable-register">>, <<"true">>}
    ,{<<"accept-blind-auth">>, <<"false">>}
    ,{<<"accept-blind-reg">>, <<"false">>}
    ,{<<"manage-presence">>, <<"false">>}
    ,{<<"manage-shared-appearance">>, <<"false">>}
    ,{<<"channel-xml-fetch-on-nightmare-transfer">>, <<"true">>}
    ,{<<"fire-transfer-events">>, <<"true">>}
    ,{<<"keep-auth-caller-id">>, <<"true">>}
    ,{<<"enable-dynamic-outbound-proxy">>, <<"true">>}
    ].
