%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2022, 2600Hz
%%% @doc Track the FreeSWITCH channel information, and provide accessors
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
-module(ecallmgr_fs_fetch_channels).

-export([channel_req/1]).
-export([init/0]).

-include("ecallmgr.hrl").
-include_lib("kazoo_sip/include/kzsip_uri.hrl").

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"fetch.channels.*.channel_req">>, ?MODULE, 'channel_req'),
    _ = kazoo_bindings:bind(<<"fetch.channels.*.query">>, ?MODULE, 'channel_req'),
    'ok'.

-spec channel_req(map()) -> 'ok'.
channel_req(#{node := Node, fetch_id := FetchId, payload := JObj} = Context) ->
    TargetUUID = kz_json:get_ne_binary_value(<<"replaces-call-id">>, JObj),
    kz_log:put_callid(JObj),
    lager:debug("received channel fetch request ~s from ~s for ~s"
               ,[FetchId, Node, TargetUUID]
               ),
    UUID = kz_json:get_ne_binary_value(<<"refer-from-channel-id">>, JObj),
    ForUUID = kz_json:get_ne_binary_value(<<"refer-for-channel-id">>, JObj),
    lager:info("request ~s is looking call ~s on ~s"
              ,[FetchId, TargetUUID, Node]),
    {'ok', ForChannel} = ecallmgr_fs_channel:fetch(ForUUID, 'proplist'),
    TargetChannel = ecallmgr_fs_channel:fetch_channel(TargetUUID),
    Channel = ecallmgr_fs_channel:fetch_channel(UUID),
    case Channel =/= 'undefined'
        andalso TargetChannel =/= 'undefined'
    of
        'false' ->
            channel_not_found(Context);
        'true' ->
            SwitchURL = props:get_ne_binary_value(<<"switch_url">>, TargetChannel),
            ToUser = kz_json:get_ne_binary_value(<<"refer-to-user">>, JObj),
            ToRealm = props:get_ne_binary_value(<<"realm">>, Channel),
            case build_sip_url(SwitchURL, ToUser, ToRealm) of
                'undefined' ->
                    lager:notice_unsafe("fetch ~s context => ~p"
                                       ,[FetchId, Context]
                                       ),
                    lager:notice_unsafe("fetch ~s channel => ~p"
                                       ,[FetchId, Channel]
                                       ),
                    lager:notice_unsafe("fetch ~s target channel => ~p"
                                       ,[FetchId, TargetChannel]
                                       ),
                    channel_not_found(Context);
                URL ->
                    CCVs = ecallmgr_fs_channel:channel_ccvs(Channel),
                    ForChannelCCVs = ecallmgr_fs_channel:channel_ccvs(ForChannel),
                    DialPrefix = channel_resp_dialprefix(JObj, Channel, CCVs, ForChannelCCVs),
                    build_channel_resp(Context#{url => URL, dial_prefix => DialPrefix})
            end
    end.

-spec build_sip_url(kz_term:api_ne_binary(), kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> kz_term:api_ne_binary().
build_sip_url('undefined', _ToUser, _ToRealm) -> 'undefined';
build_sip_url(_SwitchURL, 'undefined', _ToRealm) -> 'undefined';
build_sip_url(_SwitchURL, _ToUser, 'undefined') -> 'undefined';
build_sip_url(SwitchURL, ToUser, ToRealm) ->
    try kzsip_uri:uris(SwitchURL) of
        [URI] ->
            NewURI = #uri{user=ToUser
                         ,domain=ToRealm
                         ,opts=[{<<"fs_path">>, kzsip_uri:ruri(URI#uri{user= <<>>})}]
                         },
            kzsip_uri:ruri(NewURI);
        _ -> 'undefined'
    catch
        _E:_R:_ST ->
            lager:error("error building sip url => ~p / ~p", [_E, _R]),
            kz_log:log_stacktrace(_ST),
            'undefined'
    end.

-spec build_channel_resp(map()) -> 'ok'.
build_channel_resp(#{url := URL, dial_prefix := DialPrefix} = Context) ->
    %% NOTE
    %% valid properties to return are
    %% sip-url , dial-prefix, absolute-dial-string, sip-profile (defaulted to current channel profile)
    %% freeswitch formats the dial string with the following logic
    %% if absolute-dial-string => %s%s [dial-prefix, absolute-dial-string]
    %% else => %ssofia/%s/%s [dial-prefix, sip-profile, sip-url]
    Resp = props:filter_undefined(
             [{<<"sip-url">>, URL}
             ,{<<"dial-prefix">>, DialPrefix}
             ]),
    try_channel_resp(Context, Resp).

-spec channel_resp_dialprefix(kz_json:object(), kz_term:proplist(), kz_term:proplist(), kz_term:proplist()) -> kz_term:ne_binary().
channel_resp_dialprefix(JObj, Channel, ChannelVars, ForChannelCCVs) ->
    props:to_log(Channel, <<"TARGET CHANNEL">>),
    CallId = kz_binary:rand_hex(16),
    Props = props:filter_undefined(
              [{<<"sip_invite_domain">>, props:get_value(<<"Realm">>, ChannelVars)}
              ,{<<"sip_origination_call_id">>, CallId}

              ,{<<"ecallmgr_", ?CALL_INTERACTION_ID>>, props:get_value(<<"Call-Interaction-ID">>, ChannelVars)}
              ,{<<"ecallmgr_Account-ID">>, props:get_value(<<"Account-ID">>, ChannelVars)}
              ,{<<"ecallmgr_Realm">>, props:get_value(<<"Realm">>, ChannelVars)}
              ,{<<"ecallmgr_Authorizing-Type">>, props:get_value(<<"Authorizing-Type">>, ChannelVars)}
              ,{<<"ecallmgr_Authorizing-ID">>, props:get_value(<<"Authorizing-ID">>, ChannelVars)}
              ,{<<"ecallmgr_Owner-ID">>, props:get_value(<<"Owner-ID">>, ChannelVars)}
              ,{<<"presence_id">>, props:get_value(<<"Presence-ID">>, ChannelVars)}

              ,{<<"sip_h_X-FS-Auth-Token">>, nightmare_auth_token(ForChannelCCVs)}
              ,{<<"sip_h_X-FS-", ?CALL_INTERACTION_ID>>, props:get_value(<<"Call-Interaction-ID">>, ChannelVars)}
              ,{<<"sip_h_X-ecallmgr_Account-ID">>, props:get_value(<<"Account-ID">>, ChannelVars)}
              ,{<<"sip_h_X-FS-From-Core-UUID">>, kz_json:get_value(<<"Core-UUID">>, JObj)}
              ,{<<"sip_h_X-FS-Refer-Partner-UUID">>, props:get_value(<<"other_leg">>, Channel)}

              ]),
    fs_props_to_binary(Props).

-spec nightmare_auth_token(kz_term:proplist()) -> kz_term:api_ne_binary().
nightmare_auth_token(ChannelVars) ->
    case props:get_value(<<"Authorizing-ID">>, ChannelVars) of
        'undefined' -> 'undefined';
        AuthorizingID ->
            list_to_binary([AuthorizingID
                           ,"@"
                           ,props:get_value(<<"Account-ID">>, ChannelVars)
                           ])
    end.

-spec fs_props_to_binary(kz_term:proplist()) -> kz_term:ne_binary().
fs_props_to_binary([{Hk,Hv}|T]) ->
    Rest = << <<",", K/binary, "='", (kz_term:to_binary(V))/binary, "'">> || {K,V} <- T >>,
    <<"[", Hk/binary, "='", (kz_term:to_binary(Hv))/binary, "'", Rest/binary, "]">>.

-spec try_channel_resp(map(), kz_term:proplist()) -> 'ok'.
try_channel_resp(#{node := Node, fetch_id := FetchId} = Context, Props) ->
    try ecallmgr_fs_xml:sip_channel_xml(Props) of
        {'ok', ConfigXml} ->
            lager:debug("sending sofia XML to ~s for request ~s: ~s"
                       ,[Node, FetchId, ConfigXml]
                       ),
            freeswitch:fetch_reply(Context#{reply => erlang:iolist_to_binary(ConfigXml)})
    catch
        _E:_R:_ ->
            lager:info("sofia profile resp ~s failed to convert to XML (~s): ~p"
                      ,[FetchId, _E, _R]
                      ),
            channel_not_found(Context)
    end.

-spec channel_not_found(map()) -> 'ok'.
channel_not_found(Context) ->
    {'ok', Resp} = ecallmgr_fs_xml:not_found(),
    freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Resp)}).
