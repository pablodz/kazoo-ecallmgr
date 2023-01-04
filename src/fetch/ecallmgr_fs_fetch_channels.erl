%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2023, 2600Hz
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
    FromUUID = kz_json:get_ne_binary_value(<<"refer-from-channel-id">>, JObj),
    ForUUID = kz_json:get_ne_binary_value(<<"refer-for-channel-id">>, JObj),
    lager:info("request ~s is looking call ~s from/for (~s/~s) on ~s"
              ,[FetchId, TargetUUID, FromUUID, ForUUID, Node]),
    FromChannel = ecallmgr_fs_channel:fetch_channel(FromUUID),
    ForChannel = ecallmgr_fs_channel:fetch_channel(ForUUID),
    TargetChannel = ecallmgr_fs_channel:fetch_channel(TargetUUID),
    case FromChannel =/= 'undefined'
        andalso ForChannel =/= 'undefined'
        andalso TargetChannel =/= 'undefined'
        andalso props:get_ne_binary_value(<<"switch_url">>, TargetChannel) =/= 'undefined'
    of
        'false' ->
            lager:error_unsafe("fetch channel failed (target channel) => ~p", [TargetChannel]),
            lager:error_unsafe("fetch channel failed (from channel) => ~p", [FromChannel]),
            lager:error_unsafe("fetch channel failed (for channel) => ~p", [ForChannel]),
            channel_not_found(Context);
        'true' ->
            SwitchURL = props:get_ne_binary_value(<<"switch_url">>, TargetChannel),
            ToUser = kz_json:get_ne_binary_value(<<"refer-to-user">>, JObj),
            ToRealm = props:get_ne_binary_value(<<"realm">>, FromChannel),
            case build_sip_url(ToUser, ToRealm) of
                'undefined' ->
                    lager:notice("sip_url not build (~s/~s) ~s", [ToUser, ToRealm, kz_json:encode(JObj)]),
                    channel_not_found(Context);
                URL ->
                    build_dialprefix(Context#{url => URL
                                             ,switch_url => SwitchURL
                                             ,from_channel => FromChannel
                                             ,for_channel => ForChannel
                                             })
            end
    end.

-spec build_sip_url(kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> kz_term:api_ne_binary().
build_sip_url('undefined', _ToRealm) -> 'undefined';
build_sip_url(_ToUser, 'undefined') -> 'undefined';
build_sip_url(ToUser, ToRealm) ->
    kzsip_uri:ruri(#uri{scheme='sip', user=ToUser, domain=ToRealm}).

switch_url_transport(SwitchURL) ->
    try kzsip_uri:uris(SwitchURL) of
        [#uri{opts = Opts, ext_opts = ExtOpts}] ->
            props:get_binary_value(<<"transport">>, Opts ++ ExtOpts, <<"udp">>)
    catch
        _E:_R:_ST ->
            lager:error("error building sip url => ~p / ~p", [_E, _R]),
            kz_log:log_stacktrace(_ST),
            <<"udp">>
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

-spec build_dialprefix(map()) -> map() | 'ok'.
build_dialprefix(#{switch_url := SwitchURL
                  ,payload := JObj
                  ,from_channel := FromChannel
                  ,for_channel := ForChannel
                  } = Context) ->
    try
        DialPrefix = channel_resp_dialprefix(SwitchURL, JObj, FromChannel, ForChannel),
        build_channel_resp(Context#{dial_prefix => DialPrefix})
    catch
        _E:_R:_ST ->
            lager:error("error building dial prefix => ~p / ~p", [_E, _R]),
            kz_log:log_stacktrace(_ST),
            lager:error_unsafe("payload => ~s", [kz_json:encode(JObj)]),
            props:to_log(FromChannel, <<"FROM-CHANNEL">>),
            props:to_log(ForChannel, <<"FOR-CHANNEL">>),
            channel_not_found(Context)
    end.

-spec channel_resp_dialprefix(kz_term:api_ne_binary(), kz_json:object(), kz_term:proplist(), kz_term:proplist()) -> kz_term:ne_binary().
channel_resp_dialprefix(SwitchURL, JObj, FromChannel, ForChannel) ->
    FromChannelCCVs = ecallmgr_fs_channel:channel_ccvs(FromChannel),
    CallId = kz_binary:rand_hex(16),
    lager:debug("origination call_id for nightmare transfer => ~s", [CallId]),
    Props = props:filter_undefined(
              [{<<"sip_invite_domain">>, props:get_value(<<"Realm">>, FromChannelCCVs)}
              ,{<<"sip_origination_call_id">>, CallId}
              ,{<<"bypass_proxy">>, <<"true">>}
              ,{<<"sip_route_uri">>, SwitchURL}
              ,{<<"sip_contact_user">>, kz_json:get_ne_binary_value(<<"refer-to-user">>, JObj)}
              ,{<<"sip_transport">>, switch_url_transport(SwitchURL)}
              ,{<<"ecallmgr_", ?CALL_INTERACTION_ID>>, props:get_value(<<"interaction_id">>, FromChannel)}
              ,{<<?CALL_INTERACTION_ID>>, props:get_value(<<"interaction_id">>, FromChannel)}
              ,{<<"ecallmgr_Account-ID">>, props:get_value(<<"Account-ID">>, FromChannelCCVs)}
              ,{<<"ecallmgr_Realm">>, props:get_value(<<"Realm">>, FromChannelCCVs)}
              ,{<<"ecallmgr_Authorizing-Type">>, props:get_value(<<"Authorizing-Type">>, FromChannelCCVs)}
              ,{<<"ecallmgr_Authorizing-ID">>, props:get_value(<<"Authorizing-ID">>, FromChannelCCVs)}
              ,{<<"ecallmgr_Owner-ID">>, props:get_value(<<"Owner-ID">>, FromChannelCCVs)}
              ,{<<"presence_id">>, props:get_value(<<"Presence-ID">>, FromChannelCCVs)}
              ,{<<"sip_h_X-FS-", ?CALL_INTERACTION_ID>>, props:get_value(<<"interaction_id">>, FromChannel)}
              ,{<<"sip_h_X-ecallmgr_Account-ID">>, props:get_value(<<"Account-ID">>, FromChannelCCVs)}
              ,{<<"sip_h_X-FS-From-Core-UUID">>, kz_json:get_value(<<"Core-UUID">>, JObj)}
              ,{<<"sip_h_X-FS-Refer-Partner-UUID">>, props:get_value(<<"other_leg">>, FromChannel)}
              | nightmare_auth_token(ForChannel)
              ]),
    fs_props_to_binary(Props).

-spec nightmare_auth_token(kz_term:proplist()) -> kz_term:ne_binaries().
nightmare_auth_token(Channel) ->
    CAHs = ecallmgr_fs_channel:channel_cahs(Channel),
    case lists:foldl(fun nightmare_auth_token_args_fold/2, [], CAHs) of
        [] -> error(<<"no token available for channel">>);
        Args -> Args
    end.

nightmare_auth_token_args_fold({<<"PORT">>, _Value}, Acc) -> Acc;
nightmare_auth_token_args_fold({<<"IP">>, _Value}, Acc) -> Acc;
nightmare_auth_token_args_fold({Key, Value}, Acc) ->
    [{<<"sip_h_X-FS-AUTH-", Key/binary>>, Value} | Acc].

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
    {'ok', Resp} = ecallmgr_fs_xml:not_found(<<"channel">>),
    freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Resp)}).
