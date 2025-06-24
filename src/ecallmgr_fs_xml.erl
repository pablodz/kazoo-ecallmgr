%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2025, 2600Hz
%%% @doc Generate the XML for various FS responses
%%% @author James Aimonetti
%%% @author Karl Anderson
%%% @author Luis Azedo
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_xml).

-export([route_resp_xml/3 ,authn_resp_xml/1, reverse_authn_resp_xml/1
        ,directory_resp_endpoint_xml/3
        ,directory_resp_group_xml/3
        ,acl_xml/1, empty_response/0
        ,not_found/0, not_found/1
        ,sofia_conf_xml/1
        ,sip_channel_xml/1
        ,conference_resp_xml/1
        ,event_filters_resp_xml/1
        ,directory_resp_location_xml/2, directory_resp_location_xml/3
        ,prompt_resp_xml/2
        ]).

-export([build_leg_vars/1
        ,get_leg_vars/1
        ,get_channel_vars/1, get_channel_vars/3
        ,kazoo_var_to_fs_var/2
        ,escape/2
        ]).

-export([config_el/2, config_el/3]).
-export([section_el/2, section_el/3]).
-export([params_el/1, param_el/2, maybe_param_el/2]).
-export([xml_attrib/2]).

-export([action_el/1, action_el/2, action_el/3]).
-export([anti_action_el/1, anti_action_el/2, anti_action_el/3]).
-export([condition_el/1, condition_el/3]).
-export([extension_el/1, extension_el/2, extension_el/3]).
-export([context_el/2]).
-export([variables_el/1, variable_el/2]).
-export([hunt_context/1, context/1, context/2]).

-include("ecallmgr.hrl").

-spec acl_xml(kz_json:object()) -> {'ok', iolist()}.
acl_xml(AclsJObj) ->
    AclsFold = lists:foldl(fun arrange_acl_node/2, orddict:new(), kz_json:to_proplist(AclsJObj)),

    NetworkListEl = network_list_el([V || {_, V} <- orddict:to_list(AclsFold)]),

    ConfigEl = config_el(<<"acl.conf">>, <<"kazoo generated ACL lists">>, NetworkListEl),

    SectionEl = section_el(<<"configuration">>, ConfigEl),

    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec sip_channel_xml(kz_term:proplist()) -> {'ok', iolist()}.
sip_channel_xml(Props) ->
    ParamsEl = params_el([param_el(K, V) || {K, V} <- Props]),
    ChannelEl = channel_el(props:get_value(<<"uuid">>, Props), ParamsEl),
    SectionEl = section_el(<<"channels">>, ChannelEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec authn_expires(kz_json:object()) -> kz_term:api_integer().
authn_expires(JObj) ->
    Expires = kz_json:get_value(<<"Expires">>, JObj),
    ecallmgr_util:maybe_add_expires_deviation_ms(Expires).

-spec authn_resp_xml(kz_term:api_terms()) -> {'ok', iolist()}.
authn_resp_xml([_|_]=RespProp) ->
    authn_resp_xml(props:get_value(<<"Auth-Method">>, RespProp)
                  ,kz_json:from_list(RespProp)
                  );
authn_resp_xml(JObj) ->
    DomainName = kz_json:get_value(<<"Domain-Name">>, JObj),
    UserId = kz_json:get_value(<<"User-ID">>, JObj),

    case authn_resp_xml(kz_json:get_value(<<"Auth-Method">>, JObj), JObj) of
        {'ok', []}=OK -> OK;
        {'ok', Elements} ->
            Number = kz_json:get_value([<<"Custom-SIP-Headers">>,<<"P-Kazoo-Primary-Number">>],JObj),
            Expires = authn_expires(JObj),
            Username = kz_json:get_value(<<"Auth-Username">>, JObj, UserId),
            UserEl = user_el(user_el_props(Number, Username, Expires), Elements),
            DomainEl = domain_el(kz_json:get_value(<<"Auth-Realm">>, JObj, DomainName), UserEl),
            SectionEl = section_el(<<"directory">>, DomainEl),
            {'ok', xmerl:export([SectionEl], 'fs_xml')}
    end.

-spec authn_resp_xml(kz_term:ne_binary(), kz_json:object()) -> {'ok', kz_types:xml_els()}.
authn_resp_xml(<<"gsm">>, JObj) ->
    PassEl1 = param_el(<<"password">>, kz_json:get_value(<<"Auth-Password">>, JObj)),
    PassEl2 = param_el(<<"nonce">>, kz_json:get_value(<<"Auth-Nonce">>, JObj)),
    ParamsEl = params_el([PassEl1, PassEl2]),

    VariableEls = [variable_el(K, V) || {K, V} <- get_channel_params(JObj)],
    VariablesEl = variables_el(VariableEls),

    HeaderEls = [header_el(K, V) || {K, V} <- get_custom_sip_headers(JObj)],
    HeadersEl = registration_headers_el(HeaderEls),
    {'ok', [VariablesEl, ParamsEl, HeadersEl]};
authn_resp_xml(<<"password">>, JObj) ->
    PassEl = param_el(<<"password">>, kz_json:get_value(<<"Auth-Password">>, JObj)),
    ParamsEl = params_el([PassEl]),

    VariableEls = [variable_el(K, V) || {K, V} <- get_channel_params(JObj)],
    VariablesEl = variables_el(VariableEls),

    {'ok', [VariablesEl, ParamsEl]};
authn_resp_xml(<<"a1-hash">>, JObj) ->
    PassEl = param_el(<<"a1-hash">>, kz_json:get_value(<<"Auth-Password">>, JObj)),
    ParamsEl = params_el([PassEl]),

    VariableEls = [variable_el(K, V) || {K, V} <- get_channel_params(JObj)],
    VariablesEl = variables_el(VariableEls),

    {'ok', [VariablesEl, ParamsEl]};
authn_resp_xml(<<"ip">>, _JObj) ->
    empty_response();
authn_resp_xml(_Method, _JObj) ->
    lager:debug("unknown method ~s", [_Method]),
    empty_response().

-spec reverse_authn_resp_xml(kz_term:api_terms()) -> {'ok', iolist()}.
reverse_authn_resp_xml([_|_]=RespProp) ->
    reverse_authn_resp_xml(props:get_value(<<"Auth-Method">>, RespProp)
                          ,kz_json:from_list(RespProp)
                          );
reverse_authn_resp_xml(JObj) ->
    case reverse_authn_resp_xml(kz_json:get_value(<<"Auth-Method">>, JObj), JObj) of
        {'ok', []}=OK -> OK;
        {'ok', Elements} ->
            UserEl = user_el(kz_json:get_value(<<"User-ID">>, JObj), Elements),
            DomainEl = domain_el(kz_json:get_value(<<"Domain-Name">>, JObj), UserEl),
            SectionEl = section_el(<<"directory">>, DomainEl),
            {'ok', xmerl:export([SectionEl], 'fs_xml')}
    end.

-spec reverse_authn_resp_xml(kz_term:ne_binary(), kz_json:object()) ->
          {'ok', kz_types:xml_els()}.
reverse_authn_resp_xml(<<"password">>, JObj) ->
    UserId = kz_json:get_value(<<"User-ID">>, JObj),

    PassEl = param_el(<<"reverse-auth-pass">>, kz_json:get_value(<<"Auth-Password">>, JObj)),
    UserEl = param_el(<<"reverse-auth-user">>, kz_json:get_value(<<"Auth-Username">>, JObj, UserId)),

    ParamsEl = params_el([PassEl, UserEl]),

    VariableEls = [variable_el(K, V) || {K, V} <- get_channel_params(JObj)],
    VariablesEl = variables_el(VariableEls),

    {'ok', [VariablesEl, ParamsEl]};
reverse_authn_resp_xml(_Method, _JObj) ->
    lager:debug("unknown method ~s", [_Method]),
    empty_response().

-spec empty_response() -> {'ok', []}.
empty_response() ->
    {'ok', ""}. %"<document type=\"freeswitch/xml\"></document>").

-spec conference_resp_xml(kz_term:api_terms()) -> {'ok', iolist()}.
conference_resp_xml([_|_]=Resp) ->
    Ps = props:get_value(<<"Profiles">>, Resp, kz_json:new()),
    CCs = props:get_value(<<"Caller-Controls">>, Resp, kz_json:new()),
    As = props:get_value(<<"Advertise">>, Resp, kz_json:new()),
    CPs = props:get_value(<<"Chat-Permissions">>, Resp, kz_json:new()),

    ProfilesEl = conference_profiles_xml(Ps),
    AdvertiseEl = advertise_xml(As),
    CallerControlsEl = caller_controls_xml(CCs),
    ChatPermsEl = chat_permissions_xml(CPs),

    ConfigurationEl = config_el(<<"conference.conf">>, <<"Built by Kazoo">>
                               ,[AdvertiseEl, ProfilesEl, CallerControlsEl, ChatPermsEl]
                               ),
    SectionEl = section_el(<<"configuration">>, ConfigurationEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')};

conference_resp_xml(Resp) -> conference_resp_xml(kz_json:to_proplist(Resp)).

conference_profiles_xml(Profiles) when is_list(Profiles) ->
    ProfileEls = [conference_profile_xml(Name, Params) || {Name, Params} <- Profiles],
    profiles_el(ProfileEls);
conference_profiles_xml(Profiles) -> conference_profiles_xml(kz_json:to_proplist(Profiles)).

advertise_xml(As) when is_list(As) ->
    RoomEls = [room_el(Name, Status) || {Name, Status} <- As],
    advertise_el(RoomEls);
advertise_xml(As) -> advertise_xml(kz_json:to_proplist(As)).

caller_controls_xml(CCs) when is_list(CCs) ->
    GroupsEls = [group_xml(Name, Params) || {Name, Params} <- CCs],
    caller_controls_el(GroupsEls);
caller_controls_xml(CCs) -> caller_controls_xml(kz_json:to_proplist(CCs)).

group_xml(Name, Controls) when is_list(Controls) ->
    ControlEls = [control_el(kz_json:get_value(<<"action">>, Control)
                            ,kz_json:get_value(<<"digits">>, Control)
                            ,kz_json:get_value(<<"data">>, Control)
                            )
                  || Control <- Controls
                 ],
    group_el(Name, ControlEls);
group_xml(Name, Controls) ->
    group_xml(Name, kz_json:to_proplist(Controls)).

chat_permissions_xml(CPs) when is_list(CPs) ->
    ProfileEls = [profile_xml(Name, Users) || {Name, Users} <- CPs],
    chat_permissions_el(ProfileEls);
chat_permissions_xml(CPs) -> chat_permissions_xml(kz_json:to_proplist(CPs)).

profile_xml(Name, Users) ->
    UserEls = [chat_user_el(User, Commands) || {User, Commands} <- kz_json:to_proplist(Users)],
    profile_el(Name, UserEls).

conference_profile_xml(Name, Params) ->
    ParamEls = lists:foldl(fun conference_profile_param/2, [], kz_json:to_proplist(Params)),
    profile_el(Name, ParamEls).

conference_profile_param({<<"extra-settings">>, JObj}, Acc) ->
    lists:foldl(fun conference_profile_elem/2, Acc, kz_json:to_proplist(JObj));
conference_profile_param({<<"conference-variables">>, JObj}, Acc) ->
    VariablesEls = variables_el([variable_el(K, V) || {K, V} <- kz_json:to_proplist(JObj)]),
    Acc ++ [VariablesEls];
conference_profile_param({K, Array}, Acc) when is_list(Array) ->
    [param_el(K, kz_term:to_binary(V)) || V <- Array] ++ Acc;
conference_profile_param({K, V}, Acc) ->
    [param_el(K, kz_term:to_binary(V)) | Acc].

conference_profile_elem({K, JObj}, Acc) ->
    Children = lists:foldl(fun conference_profile_param/2, [], kz_json:to_proplist(JObj)),
    [named_el(kz_term:to_atom(K, 'true'), Children) | Acc].

-spec route_resp_xml(atom(), kz_term:api_terms(), dialplan_context()) -> {'ok', iolist()}.
route_resp_xml(Section, [_|_]=RespProp, DialplanContext) ->
    route_resp_xml(Section, kz_json:from_list(RespProp), DialplanContext);
route_resp_xml(Section, RespJObj, DialplanContext) ->
    route_resp_xml(kz_json:get_value(<<"Method">>, RespJObj)
                  ,kz_json:get_value(<<"Routes">>, RespJObj, [])
                  ,kz_json:set_value(<<"Fetch-Section">>, kz_term:to_binary(Section), RespJObj)
                  ,DialplanContext
                  ).

%% Prop = Route Response
-type route_resp_fold_acc() :: {pos_integer(), kz_types:xml_els()}.

-spec route_resp_fold(kz_json:object(), route_resp_fold_acc()) ->
          route_resp_fold_acc().
route_resp_fold(RouteJObj, {Idx, Acc}) ->
    case ecallmgr_util:build_channel(RouteJObj) of
        {'error', _} -> {Idx+1, Acc};
        {'ok', Channel} ->
            route_resp_fold(RouteJObj, {Idx, Acc}, Channel)
    end.

-spec route_resp_fold(kz_json:object(), route_resp_fold_acc(), kz_term:ne_binary()) ->
          route_resp_fold_acc().
route_resp_fold(RouteJObj, {Idx, Acc}, Channel) ->
    RouteJObj1 =
        case kz_json:get_value(<<"Progress-Timeout">>, RouteJObj) of
            'undefined' ->
                kz_json:set_value(<<"Progress-Timeout">>, <<"6">>, RouteJObj);
            I when is_integer(I) ->
                kz_json:set_value(<<"Progress-Timeout">>, integer_to_list(I), RouteJObj);
            _ -> RouteJObj
        end,

    ChannelVars = get_channel_vars(kz_json:to_proplist(RouteJObj1)),

    BPEl = action_el(<<"set">>, [<<"bypass_media=">>, should_bypass_media(RouteJObj)]),
    HangupEl = action_el(<<"set">>, <<"hangup_after_bridge=true">>),
    FailureEl = action_el(<<"set">>, <<"failure_causes=NORMAL_CLEARING,ORIGINATOR_CANCEL,CRASH">>),
    BridgeEl = action_el(<<"bridge">>, [ChannelVars, Channel]),

    ConditionEl = condition_el([BPEl, HangupEl, FailureEl, BridgeEl]),
    ExtEl = extension_el([<<"match_">>, Idx+$0], <<"true">>, [ConditionEl]),

    {Idx+1, [ExtEl | Acc]}.

-spec should_bypass_media(kz_json:object()) -> string().
should_bypass_media(RouteJObj) ->
    case kz_json:get_value(<<"Media">>, RouteJObj) of
        <<"bypass">> -> "true";
        _ -> "false" %% default to not bypassing media
    end.

-spec route_resp_xml(kz_term:ne_binary(), kz_json:objects(), kz_json:object(), dialplan_context()) -> {'ok', iolist()}.
route_resp_xml(<<"bridge">>, Routes, JObj, DialplanContext) ->
    lager:debug("creating a bridge XML response"),
    Bridge = [route_resp_progress(JObj)
             ,route_resp_log_winning_node()
             ,route_resp_set_winning_node()
             ,route_resp_bridge_id()
             ,route_resp_ccvs(JObj)
             ,route_resp_cavs(JObj)
             ,route_resp_ringback(JObj)
             ,route_resp_transfer_ringback(JObj)
             ],
    Actions = [E || E <- Bridge, E =/= 'undefined'],

    %% format the Route based on protocol
    {_Idx, Extensions} = lists:foldr(fun route_resp_fold/2, {1, []}, Routes),

    FailRespondEl = action_el(<<"respond">>, <<"${bridge_hangup_cause}">>),
    FailConditionEl = condition_el(FailRespondEl),
    FailExtEl = extension_el(<<"failed_bridge">>, <<"false">>, [FailConditionEl]),

    Context = context(JObj, DialplanContext),
    ContextContent = Actions ++ maybe_unset_custom_sip_headers() ++ Extensions ++ [FailExtEl],
    ContextEl = context_el(Context, ContextContent),
    SectionEl = section_el(<<"dialplan">>, <<"Route Bridge Response">>, ContextEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')};

route_resp_xml(<<"park">>, _Routes, JObj, DialplanContext) ->
    Exten = route_resp_park_xml(JObj, DialplanContext),
    ParkExtEl = extension_el(<<"park">>, 'undefined', [condition_el(Exten)]),
    Context = context(JObj, DialplanContext),
    ContextEl = context_el(Context, [ParkExtEl]),
    SectionEl = section_el(<<"dialplan">>, <<"Route Park Response">>, ContextEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')};

route_resp_xml(<<"error">>, Routes, JObj, DialplanContext) ->
    Section = kz_json:get_value(<<"Fetch-Section">>, JObj, <<"dialplan">>),
    route_resp_xml(<<Section/binary, "_error">>, Routes, JObj, DialplanContext);

route_resp_xml(<<"dialplan_error">>, _Routes, JObj, DialplanContext) ->
    ErrCode = kz_json:get_value(<<"Route-Error-Code">>, JObj),
    ErrMsg = [" ", kz_json:get_value(<<"Route-Error-Message">>, JObj, <<>>)],
    Exten = [route_resp_log_winning_node()
            ,route_resp_set_winning_node()
            ,route_resp_bridge_id()
            ,route_resp_ringback(JObj)
            ,route_resp_transfer_ringback(JObj)
            ,route_resp_ccvs(JObj)
            ,route_resp_cavs(JObj)
            ,action_el(<<"respond">>, [ErrCode, ErrMsg])
            ],
    ErrExtEl = extension_el([condition_el(Exten)]),
    Context = context(JObj, DialplanContext),
    ContextEl = context_el(Context, [ErrExtEl]),
    SectionEl = section_el(<<"dialplan">>, <<"Route Error Response">>, ContextEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')};

route_resp_xml(<<"chatplan_error">>, _Routes, JObj, _DialplanContext) ->
    ErrCode = kz_json:get_value(<<"Route-Error-Code">>, JObj),
    ErrMsg = [" ", kz_json:get_value(<<"Route-Error-Message">>, JObj, <<>>)],
    Exten = [route_resp_log_winning_node()
            ,route_resp_set_winning_node()
            ,route_resp_bridge_id()
            ,route_resp_ccvs(JObj)
            ,route_resp_cavs(JObj)
            ,action_el(<<"reply">>, [ErrCode, ErrMsg])
            ],
    ErrExtEl = extension_el([condition_el(Exten)]),
    ContextEl = context_el(?DEFAULT_FREESWITCH_CONTEXT, [ErrExtEl]),
    SectionEl = section_el(<<"chatplan">>, <<"Route Error Response">>, ContextEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')};

route_resp_xml(<<"sms">>, _Routes, _JObj, DialplanContext) ->
    lager:debug("creating a chatplan XML response"),
    StopActionEl = action_el(<<"stop">>, <<"stored">>),
    StopExtEl = extension_el(<<"chat plan">>, <<"false">>, [condition_el([StopActionEl])]),
    Context = hunt_context(DialplanContext),
    ContextEl = context_el(Context, [StopExtEl]),
    SectionEl = section_el(<<"chatplan">>, <<"Chat Response">>, ContextEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')};

route_resp_xml(<<"sms_error">>, _Routes, JObj, _DialplanContext) ->
    ErrCode = kz_json:get_value(<<"Route-Error-Code">>, JObj),
    ErrMsg = [" ", kz_json:get_value(<<"Route-Error-Message">>, JObj, <<>>)],
    Exten = [route_resp_log_winning_node()
            ,route_resp_set_winning_node()
            ,route_resp_bridge_id()
            ,route_resp_ccvs(JObj)
            ,route_resp_cavs(JObj)
            ,action_el(<<"respond">>, [ErrCode, ErrMsg])
            ],
    ErrExtEl = extension_el([condition_el(Exten)]),
    ContextEl = context_el(?DEFAULT_FREESWITCH_CONTEXT, [ErrExtEl]),
    SectionEl = section_el(<<"chatplan">>, <<"Route Error Response">>, ContextEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')};

route_resp_xml(Method, Routes, JObj, #{'route_resp_xml_fun' := Fun}=DialplanContext)
  when is_function(Fun, 4) ->
    lager:debug("trying fun for ~p", [Method]),
    Fun(Method, Routes, JObj, DialplanContext);
route_resp_xml(Method, Routes, JObj, DialplanContext) ->
    lager:error("route resp xml method ~p not handled, reverting to error", [Method]),
    route_resp_xml(<<"error">>, Routes, JObj, DialplanContext).

-spec not_found() -> {'ok', iolist()}.
not_found() ->
    not_found(<<"Route">>).

-spec not_found(kz_term:ne_binary()) -> {'ok', iolist()}.
not_found(Name) ->
    ResultEl = result_el(<<"not found">>),
    SectionEl = section_el(<<"result">>, <<Name/binary, " Not Found">>, ResultEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec route_resp_park() -> kz_types:xml_el().
route_resp_park() ->
    action_el(<<"park">>).

-spec route_resp_bridge_id() -> kz_types:xml_el().
route_resp_bridge_id() ->
    Action = action_el(<<"export">>, [?SET_CCV(<<"Bridge-ID">>, <<"${UUID}">>)], 'true'),
    condition_el(Action, <<"${", (?CCV(<<"Bridge-ID">>))/binary, "}">>, <<"^$">>).

-spec route_resp_set_originating_proxy(dialplan_context()) -> kz_types:xml_el() | 'undefined'.
route_resp_set_originating_proxy(#{payload := Payload}) ->
    case kz_json:get_ne_binary_value(<<"Originating-Proxy">>, Payload) of
        'undefined' -> 'undefined';
        Proxy -> action_el(<<"set">>, list_to_binary([<<"originating_proxy=">>, Proxy]))
    end.

-spec unset_custom_sip_headers() -> kz_types:xml_el() | 'undefined'.
unset_custom_sip_headers() ->
    case unset_cshs() of
        <<>> -> 'undefined';
        CSHs -> action_el(<<"kz_prefix_unset">>, CSHs)
    end.

-spec maybe_unset_custom_sip_headers() -> kz_types:xml_els().
maybe_unset_custom_sip_headers() ->
    case unset_custom_sip_headers() of
        'undefined' -> [];
        Action -> [Action]
    end.

unset_cshs() ->
    kz_binary:join(lists:map(fun(CSH) -> <<"sip_h_", CSH/binary>> end, unset_csh_list()), <<"|">>).

unset_csh_list() ->
    kz_app_config:get_ne_binaries(?APP, <<"dialplan.route_resp.park.unset-cshs">>, default_unset_csh_list()).

default_unset_csh_list() -> [].

-spec route_resp_log_winning_node() -> kz_types:xml_el().
route_resp_log_winning_node() ->
    action_el(<<"log">>, [<<"NOTICE log|${uuid}|", (kz_term:to_binary(node()))/binary, " won call control">>]).

route_resp_set_winning_node() ->
    action_el(<<"export">>, [?SET_CCV(<<"Ecallmgr-Node">>, (kz_term:to_binary(node())))], 'true').

-spec route_resp_fire_route_win(kz_json:object(), dialplan_context()) -> kz_types:xml_el().
route_resp_fire_route_win(JObj, #{'control_q' := ControlQ
                                 ,'fetch_id' := FetchId
                                 }) ->
    Params = [{<<"Event-Subclass">>, ?ROUTE_WINNER_EVENT}
             ,{<<"Event-Name">>, <<"CUSTOM">>}
             ,{<<"Event-Category">>, <<"dialplan">>}
             ,{<<"Routing-Queue">>, kapi:encode_pid(ControlQ, self())}
             ,{<<"Request-From-PID">>, kz_term:to_binary(self())}
             ,{<<"Controller-Queue">>, kz_api:server_id(JObj)}
             ,{<<"Fetch-UUID">>, FetchId}
             ],
    Args = [<<K/binary, "=", V/binary>> || {K, V} <- Params, kz_term:is_not_empty(V)],
    EventApp = kz_app_config:get_ne_binary(?APP, [<<"dialplan">>, <<"apps">>, <<"event">>], <<"kz_deliver_event">>),
    action_el(EventApp, kz_binary:join(Args, <<",">>)).

-spec route_resp_channel_update(kz_json:object(), dialplan_context()) -> kz_types:xml_el().
route_resp_channel_update(_JObj, _Context) ->
    Params = [{<<"Event-Name">>, <<"CHANNEL_DATA">>}],
    Args = [<<K/binary, "=", V/binary>> || {K, V} <- Params, kz_term:is_not_empty(V)],
    EventApp = kz_app_config:get_ne_binary(?APP, [<<"dialplan">>, <<"apps">>, <<"event">>], <<"kz_deliver_event">>),
    action_el(EventApp, kz_binary:join(Args, <<",">>)).

-spec route_resp_ringback(kz_json:object()) -> kz_types:xml_el().
route_resp_ringback(JObj) ->
    case kz_json:get_value(<<"Ringback-Media">>, JObj) of
        'undefined' ->
            {'ok', RBSetting} = ecallmgr_util:get_setting(<<"default_ringback">>),
            action_el(<<"set">>, <<"ringback=", (kz_term:to_binary(RBSetting))/binary>>);
        Media ->
            MsgId = kz_api:msg_id(JObj),
            Stream = ecallmgr_util:media_path(Media, 'extant', MsgId, JObj),
            action_el(<<"set">>, <<"ringback=", (kz_term:to_binary(Stream))/binary>>)
    end.

no_channel_data_updates(Bin) ->
    list_to_binary(["%^[No-Channel-Data=true]", Bin]).

-spec route_resp_ccvs(kz_json:object()) -> kz_types:xml_el().
route_resp_ccvs(JObj) ->
    CCVs = [{<<"Application-Name">>, kz_json:get_value(<<"App-Name">>, JObj)}
           ,{<<"Application-Node">>, kz_json:get_value(<<"Node">>, JObj)}
           | kz_json:to_proplist(<<"Custom-Channel-Vars">>, JObj)
           ],
    action_el(<<"kz_multiset_encoded">>, no_channel_data_updates(route_ccvs_list(CCVs))).

-spec route_resp_cavs(kz_json:object()) -> kz_types:xml_el() | 'undefined'.
route_resp_cavs(JObj) ->
    CAVs = kz_json:get_json_value(<<"Custom-Application-Vars">>, JObj, kz_json:new()),
    case kz_json:to_proplist(CAVs) of
        [] -> 'undefined';
        Props -> action_el(<<"kz_multiset_encoded">>, no_channel_data_updates(route_cavs_list(Props)))
    end.

-spec route_ccvs_list(kz_term:proplist()) -> kz_term:ne_binary().
route_ccvs_list(CCVs) ->
    L = [kz_term:to_list(ecallmgr_util:get_fs_kv(K, V))
         || {K, V} <- CCVs
        ],
    <<"^^|", (kz_term:to_binary(string:join(L, "|")))/binary>>.

-spec route_cavs_list(kz_term:proplist()) -> kz_term:ne_binary().
route_cavs_list(CAVs) ->
    L = [kz_term:to_list(ecallmgr_util:get_fs_kv(?CAV(K), V))
         || {K, V} <- CAVs
        ],
    <<"^^|", (kz_term:to_binary(string:join(L, "|")))/binary>>.

-spec route_resp_transfer_ringback(kz_json:object()) -> kz_types:xml_el().
route_resp_transfer_ringback(JObj) ->
    case kz_json:get_value(<<"Transfer-Media">>, JObj) of
        'undefined' ->
            {'ok', RBSetting} = ecallmgr_util:get_setting(<<"default_ringback">>),
            action_el(<<"set">>, <<"transfer_ringback=", (kz_term:to_binary(RBSetting))/binary>>);
        Media ->
            MsgId = kz_json:get_value(<<"Msg-ID">>, JObj),
            Stream = ecallmgr_util:media_path(Media, 'extant', MsgId, JObj),
            action_el(<<"set">>, <<"transfer_ringback=", (kz_term:to_binary(Stream))/binary>>)
    end.

-spec route_resp_pre_park_action(kz_json:object()) -> 'undefined' | kz_types:xml_el().
route_resp_pre_park_action(JObj) ->
    case kz_json:get_value(<<"Pre-Park">>, JObj) of
        <<"ring_ready">> ->
            case kz_json:is_true(<<"Ignore-Progress">>, JObj, 'false') of
                'true' -> action_el(<<"ring_ready">>);
                'false' -> 'undefined'
            end;
        <<"answer">> -> action_el(<<"answer">>);
        _Else -> 'undefined'
    end.

-spec route_resp_progress(kz_json:object()) -> 'undefined' | kz_types:xml_el().
route_resp_progress(JObj) ->
    case kz_json:is_true(<<"Ignore-Progress">>, JObj, 'false') of
        'true' -> 'undefined';
        'false' -> action_el(<<"ring_ready">>, 'undefined', 'true')
    end.

-spec maybe_start_dtmf_action(dialplan_context()) -> 'undefined' | kz_types:xml_el().
maybe_start_dtmf_action(DialplanContext) ->
    case kapps_config:is_true(?APP_NAME, <<"should_detect_inband_dtmf">>, 'false') of
        'false' -> 'undefined';
        'true' -> check_dtmf_type(DialplanContext)
    end.

-spec check_dtmf_type(dialplan_context()) -> 'undefined' | kz_types:xml_el().
check_dtmf_type(#{payload := Payload}) ->
    case kz_json:get_value(<<"variable_switch_r_sdp">>, Payload, <<"101 telephone-event">>) of
        <<"101 telephone-event">> -> 'undefined';
        _ -> action_el(<<"start_dtmf">>)
    end.

-spec build_leg_vars(kz_json:object() | kz_term:proplist()) -> kz_term:ne_binaries().
build_leg_vars([]) -> [];
build_leg_vars([_|_]=Prop) ->
    lists:foldr(fun kazoo_var_to_fs_var/2, maybe_endpoint_privacy_header(Prop), Prop);
build_leg_vars(JObj) -> build_leg_vars(kz_json:to_proplist(JObj)).

-spec get_leg_vars(kz_json:object() | kz_term:proplist()) -> iolist().
get_leg_vars([]) -> [];
get_leg_vars([Binary|_]=Binaries)
  when is_binary(Binary) ->
    ["[^^", ?BRIDGE_CHANNEL_VAR_SEPARATOR
    ,string:join([kz_term:to_list(V) || V <- Binaries]
                ,?BRIDGE_CHANNEL_VAR_SEPARATOR
                )
    ,"]"
    ];
get_leg_vars([_|_]=Prop) ->
    ["[^^", ?BRIDGE_CHANNEL_VAR_SEPARATOR
    ,string:join([kz_term:to_list(V)
                  || V <- lists:foldr(fun kazoo_var_to_fs_var/2
                                     ,maybe_endpoint_privacy_header(Prop)
                                     ,Prop
                                     )
                 ]
                ,?BRIDGE_CHANNEL_VAR_SEPARATOR
                )
    ,"]"
    ];
get_leg_vars(JObj) -> get_leg_vars(kz_json:to_proplist(JObj)).

-spec maybe_endpoint_privacy_header(kz_term:proplist()) -> kz_term:ne_binaries().
maybe_endpoint_privacy_header(Prop) ->
    case kz_privacy:has_flags(Prop)
        andalso kz_privacy:use_sip_privacy_header()
    of
        'true' -> [<<"sip_h_Privacy=id">>];
        'false' -> []
    end.

-spec get_channel_vars(kz_json:object() | kz_term:proplist()) -> iolist().
get_channel_vars(Param) ->
    get_channel_vars(Param, "<", ">").

-spec get_channel_vars(kz_json:object() | kz_term:proplist(), string(), string()) -> iolist().
get_channel_vars(Param, Open, Close) ->
    [Open
    ,string:join([kz_term:to_list(Result)
                  || Result <- channel_vars(Param)
                 ]
                ,","
                )
    ,Close
    ].

-spec channel_vars(kz_json:object() | kz_term:proplist()) -> iolist().
channel_vars([]) -> [];
channel_vars([_|_]=Props) ->
    Routines = [fun channel_vars_set_overwrite/1
               ,fun channel_vars_handle_asserted_identity/1
               ,fun kazoo_vars_to_fs_vars/1
               ],
    {_, Results} =
        lists:foldl(fun(F, Acc) ->
                            F(Acc)
                    end
                   ,{Props, []}
                   ,Routines
                   ),
    Results;
channel_vars(JObj) -> channel_vars(kz_json:to_proplist(JObj)).

-type channel_var_fold() :: {kz_term:proplist(), iolist()}.
-spec channel_vars_set_overwrite(channel_var_fold()) -> channel_var_fold().
channel_vars_set_overwrite({Props, Results}) ->
    {Props ++ [{<<"Overwrite-Channel-Vars">>, <<"true">>}]
    ,Results
    }.

-spec channel_vars_handle_asserted_identity(channel_var_fold()) -> channel_var_fold().
channel_vars_handle_asserted_identity({Props, Results}=Acc) ->
    Name = props:get_ne_binary_value(<<"Asserted-Identity-Name">>, Props),
    Number = props:get_ne_binary_value(<<"Asserted-Identity-Number">>, Props),
    CCVs = props:get_value(<<"Custom-Channel-Vars">>, Props, kz_json:new()),
    DefaultRealm = kz_json:get_ne_binary_value(<<"Realm">>, CCVs),
    Realm = props:get_ne_binary_value(<<"Asserted-Identity-Realm">>, Props, DefaultRealm),
    case create_asserted_identity_header(Name, Number, Realm) of
        'undefined' -> Acc;
        AssertedIdentity ->
            build_asserted_identity(AssertedIdentity, props:delete(<<"Caller-ID-Type">>, Props), Results)
    end.


-spec build_asserted_identity(kz_term:ne_binary(), kz_term:proplist(), iolist()) -> channel_var_fold().
build_asserted_identity(AssertedIdentity, Props, Results) ->
    {Props
    ,[<<"sip_cid_type=none">>
     ,<<"sip_h_P-Asserted-Identity='", AssertedIdentity/binary, "'">>
     | Results
     ] ++ maybe_endpoint_privacy_header(Props)
    }.

-spec create_asserted_identity_header(kz_term:api_binary(), kz_term:api_binary(), kz_term:api_binary()) ->
          kz_term:api_binary().
create_asserted_identity_header(_, 'undefined', _) ->
    'undefined';
create_asserted_identity_header(_, _, 'undefined') ->
    'undefined';
create_asserted_identity_header('undefined', Number, Realm) ->
    <<"<sip:", Number/binary, "@", Realm/binary, ">">>;
create_asserted_identity_header(Name, Number, Realm) ->
    <<$", Name/binary, $", " <sip:", Number/binary, "@", Realm/binary, ">">>.

-spec kazoo_vars_to_fs_vars(channel_var_fold() | kz_term:proplist()) -> channel_var_fold().
kazoo_vars_to_fs_vars({Props, Results}) ->
    {[], lists:foldr(fun kazoo_var_to_fs_var/2, Results, kazoo_merge_vars(Props))};
kazoo_vars_to_fs_vars(Props) ->
    kazoo_vars_to_fs_vars({Props, []}).

-spec kazoo_var_to_fs_var({binary(), binary() | kz_json:object()}, kz_term:ne_binaries()) -> iolist().
kazoo_var_to_fs_var({<<"Custom-Channel-Vars">>, JObj}, Vars) ->
    kz_json:foldl(fun kazoo_var_to_fs_var_fold/3, Vars, kazoo_merge_vars(JObj));

kazoo_var_to_fs_var({<<"Custom-Application-Vars">>, JObj}, Vars) ->
    kz_json:foldl(fun kazoo_cavs_to_fs_vars_fold/3, Vars, JObj);

kazoo_var_to_fs_var({<<"Custom-Profile-Vars">>, JObj}, Vars) ->
    kz_json:foldl(fun get_profile_vars_fold/3, Vars, JObj);

kazoo_var_to_fs_var({<<"Custom-SIP-Headers">>, SIPJObj}, Vars) ->
    kz_json:foldl(fun sip_headers_fold/3, Vars, SIPJObj);

kazoo_var_to_fs_var({<<"To-User">>, Username}, Vars) ->
    Prefix = [?CHANNEL_VAR_PREFIX, "Username"],
    [encode_fs_val(Prefix, Username) | Vars];
kazoo_var_to_fs_var({<<"To-Realm">>, Realm}, Vars) ->
    Prefix = [?CHANNEL_VAR_PREFIX, "Realm"],
    [encode_fs_val(Prefix, Realm) | Vars];
kazoo_var_to_fs_var({<<"To-URI">>, ToURI}, Vars) ->
    Val = <<"<", ToURI/binary, ">">>,
    [encode_fs_val("sip_invite_to_uri", Val) | Vars];

kazoo_var_to_fs_var({<<"Caller-ID-Type">>, <<"from">>}, Vars) ->
    [ <<"sip_cid_type=none">> | Vars];
kazoo_var_to_fs_var({<<"Caller-ID-Type">>, <<"rpid">>}, Vars) ->
    [ <<"sip_cid_type=rpid">> | Vars];
kazoo_var_to_fs_var({<<"Caller-ID-Type">>, <<"pid">>}, Vars) ->
    [ <<"sip_cid_type=pid">> | Vars];

kazoo_var_to_fs_var({<<"origination_uuid">> = K, UUID}, Vars) ->
    [encode_fs_val(K, UUID) | Vars];

kazoo_var_to_fs_var({<<"Merged-Hold-Media">>, JObj}, Vars) ->
    MediaPath = ecallmgr_util:moh_media_path('extant', get('callid'), JObj),
    [encode_fs_val("hold_music", MediaPath) | Vars];

kazoo_var_to_fs_var({<<"Hold-Media">>, Media}, Vars) ->
    MediaPath = ecallmgr_util:moh_media_path(Media, 'extant', get('callid'), kz_json:new()),
    [encode_fs_val("hold_music", MediaPath) | Vars];

kazoo_var_to_fs_var({<<"Codecs">>, []}, Vars) ->
    Vars;
kazoo_var_to_fs_var({<<"Codecs">>, Cs}, Vars) ->
    Codecs = [codec_mappings(C)
              || C <- Cs,
                 not kz_term:is_empty(C)
             ],
    Val = kz_binary:join(Codecs, <<",">>),
    [encode_fs_val("absolute_codec_string", Val) | Vars];

%% SPECIAL CASE: Timeout must be larger than zero
kazoo_var_to_fs_var({<<"Timeout">>, V}, Vars) ->
    case kz_term:to_integer(V) of
        TO when TO > 0 ->
            [<<"call_timeout=", (kz_term:to_binary(TO))/binary>>
            ,<<"originate_timeout=", (kz_term:to_binary(TO))/binary>>
            | Vars
            ];
        _Else -> Vars
    end;

kazoo_var_to_fs_var({<<"Forward-IP">>, <<"sip:", _/binary>>=V}, Vars) ->
    [encode_fs_val("sip_route_uri", V) | Vars];

kazoo_var_to_fs_var({<<"Forward-IP">>, V}, Vars) ->
    kazoo_var_to_fs_var({<<"Forward-IP">>, <<"sip:", V/binary>>}, Vars);

kazoo_var_to_fs_var({<<"Enable-T38-Gateway">>, Direction}, Vars) ->
    Val = <<"t38_gateway ", Direction/binary>>,
    [encode_fs_val("execute_on_answer", Val) | Vars];

kazoo_var_to_fs_var({<<"Confirm-File">>, V}, Vars) ->
    Val = ecallmgr_util:media_path(V, 'extant', get('callid'), kz_json:new()),
    [encode_fs_val("group_confirm_file", Val) | Vars];

kazoo_var_to_fs_var({<<"Confirm-Play-Count">>, V}, Vars) ->
    [encode_fs_val("group_confirm_play_count", V)
    ,encode_fs_val("group_confirm_timeout", 0)
    | Vars
    ];

kazoo_var_to_fs_var({<<"SIP-Invite-Parameters">>, V}, Vars) ->
    Val = kz_term:iolist_join(<<";">>, V),
    [encode_fs_val("sip_invite_params", Val) | Vars];

kazoo_var_to_fs_var({<<"Participant-Flags">>, [_|_]=Flags}, Vars) ->
    ParticipantFlags = participant_flags_to_var(Flags),
    Val = <<"^^!", ParticipantFlags/binary>>,
    [encode_fs_val("conference_member_flags", Val) | Vars];

kazoo_var_to_fs_var({<<"Call-Context">>, JObj}, Vars) ->
    Val = kz_json:encode(JObj),
    [encode_fs_val("kz-endpoint-runtime-context", Val) | Vars];

kazoo_var_to_fs_var({<<"SIP-Diversions">>, V}, Vars) ->
    [encode_fs_val("sip_h_Diversion",  encode_sip_diversions(V)) | Vars];

kazoo_var_to_fs_var({<<"SIP-Multiparts">>, JObj}, Vars) ->
    kz_json:foldl(fun encode_sip_multiparts_fold/3, Vars, JObj);

kazoo_var_to_fs_var({AMQPHeader, V}, Vars) ->
    case lists:keyfind(AMQPHeader, 1, ?SPECIAL_CHANNEL_VARS) of
        'false' -> Vars;
        {_, Prefix} ->
            Val = ecallmgr_util:maybe_sanitize_fs_value(AMQPHeader, V),
            [encode_fs_val(Prefix, Val) | Vars]
    end;
kazoo_var_to_fs_var(_, Vars) -> Vars.


kazoo_merge_vars(Props) when is_list(Props) ->
    kz_json:to_proplist(kazoo_merge_vars(kz_json:from_list(Props)));
kazoo_merge_vars(JObj) ->
    Routines = [fun kazoo_merge_hold_media/1],
    lists:foldl(fun kazoo_merge_vars_fold/2, JObj, Routines).

kazoo_merge_vars_fold(Fun, JObj) -> Fun(JObj).

kazoo_merge_hold_media(JObj) ->
    Keys = [{<<"Hold-Media">>, [<<"Merged-Hold-Media">>, <<"Hold-Media">>]}
           ,{<<"Hold-Media-Options">>, [<<"Merged-Hold-Media">>, <<"Hold-Media-Options">>]}
           ,{<<"Custom-Hold-Media">>, [<<"Merged-Custom-Hold-Media">>, <<"Hold-Media">>]}
           ,{<<"Custom-Hold-Media-Options">>, [<<"Merged-Custom-Hold-Media">>, <<"Hold-Media-Options">>]}
           ],
    lists:foldl(fun kazoo_merge_hold_media_fold/2, JObj, Keys).

kazoo_merge_hold_media_fold({Key, NewKey}, JObj) ->
    case kz_json:get_value(Key, JObj) of
        'undefined' -> JObj;
        Value -> kz_json:set_value(NewKey, Value, kz_json:delete_key(Key, JObj))
    end.

-spec participant_flags_to_var(kz_term:ne_binaries()) -> kz_term:ne_binary().
participant_flags_to_var(Flags) ->
    kz_binary:join(lists:map(fun participant_flag_to_var/1, Flags), <<"!">>).

-spec participant_flag_to_var(kz_term:ne_binary()) -> kz_term:ne_binary().
participant_flag_to_var(<<"distribute_dtmf">>) -> <<"dist-dtmf">>;
participant_flag_to_var(<<"is_moderator">>) -> <<"moderator">>;
participant_flag_to_var(<<"disable_moh">>) -> <<"nomoh">>;
participant_flag_to_var(<<"join_existing">>) -> <<"join-only">>;
participant_flag_to_var(<<"video_mute">>) -> <<"vmute">>;
participant_flag_to_var(Flag) -> Flag.

-spec sip_headers_fold(kz_json:path(), kz_json:json_term(), iolist()) -> iolist().
sip_headers_fold(<<"Diversions">>, Vs, Vars) ->
    diversion_headers_fold(Vs, Vars);
sip_headers_fold(K, V, Vars) ->
    Prefix = ["sip_h_", K],
    Val = maybe_expand_macro(kz_term:to_binary(V)),
    [encode_fs_val(Prefix, Val) | Vars].

-define(DEFAULT_EXPANDABLE_MACROS
       ,kz_json:from_list([{<<"{caller_id_name}">>, <<"${caller_id_name}">>}
                          ,{<<"{caller_id_number}">>, <<"${caller_id_number}">>}
                          ,{<<"{account_id}">>, <<"${" ?CHANNEL_VAR_PREFIX "Account-ID}">>}
                          ,{<<"{reseller_id}">>, <<"${" ?CHANNEL_VAR_PREFIX "Reseller-ID}">>}
                          ,{<<"{billing_id}">>, <<"${" ?CHANNEL_VAR_PREFIX "Billing-ID}">>}
                          ])).
-define(EXPANDABLE_MACROS, kapps_config:get_json(?APP_NAME, <<"expandable_macros">>, ?DEFAULT_EXPANDABLE_MACROS)).

-spec expandable_macros() -> kz_json:object().
expandable_macros() ->
    Routines = [fun add_cluster_id_macro/1],
    kz_json:exec(Routines, kz_json:merge(?DEFAULT_EXPANDABLE_MACROS, ?EXPANDABLE_MACROS)).

-spec add_cluster_id_macro(kz_json:object()) -> kz_json:object().
add_cluster_id_macro(JObj) ->
    kz_json:set_value(<<"{cluster_id}">>, kzd_cluster:id(), JObj).

-spec maybe_expand_macro(kz_term:ne_binary()) -> kz_term:ne_binary().
maybe_expand_macro(<<"{", _/binary>> = HeaderValue) ->
    kz_json:get_ne_binary_value(HeaderValue, expandable_macros(), HeaderValue);
maybe_expand_macro(HeaderValue) -> HeaderValue.

-spec diversion_headers_fold(kz_term:ne_binaries(), iolist()) -> iolist().
diversion_headers_fold(Vs, Vars0) ->
    lists:foldl(fun diversion_header_fold/2, Vars0, Vs).

-spec diversion_header_fold(kz_term:ne_binary(), iolist()) -> iolist().
diversion_header_fold(<<_/binary>> = V, Vars0) ->
    lager:debug("setting diversion ~s on the channel", [V]),
    [encode_fs_val("sip_h_Diversion", V) | Vars0].

-spec kazoo_var_to_fs_var_fold(kz_json:path(), kz_json:json_term(), iolist()) -> iolist().
kazoo_var_to_fs_var_fold(<<"Force-Fax">>, Direction, Acc) ->
    Val = <<"t38_gateway ", Direction/binary>>,
    [encode_fs_val("execute_on_answer", Val) | Acc];

kazoo_var_to_fs_var_fold(<<?CHANNEL_LOOPBACK_HEADER_PREFIX, K/binary>>, V, Acc) ->
    Prefix = <<?CHANNEL_LOOPBACK_HEADER_PREFIX, (ecallmgr_util:get_fs_key(K))/binary>>,
    Val = kz_term:to_list(V),
    [encode_fs_val(Prefix, Val) | Acc];

kazoo_var_to_fs_var_fold(<<"Loopback-Export">> = Key, Vars, Acc) ->
    Prefix = ecallmgr_util:get_fs_key(Key),
    Val = kz_binary:join([ecallmgr_util:get_fs_key(Var) || Var <- Vars], <<",">>),
    [encode_fs_val(Prefix, Val) | Acc];

kazoo_var_to_fs_var_fold(<<"Loopback-Request-Variables">> = Key, Vars, Acc) ->
    Prefix = ecallmgr_util:get_fs_key(Key),
    Val = kz_binary:join([ecallmgr_util:get_fs_key(Var) || Var <- Vars], <<",">>),
    [encode_fs_val(Prefix, Val) | Acc];

kazoo_var_to_fs_var_fold(<<"Media-Control">>, Variables, Acc) ->
    kz_json:foldl(fun media_control_fold/3, Acc, Variables);

kazoo_var_to_fs_var_fold(<<"Channel-Actions">>, Actions, Acc) ->
    [Actions |Acc];

kazoo_var_to_fs_var_fold(K, V, Acc) ->
    case lists:keyfind(K, 1, ?SPECIAL_CHANNEL_VARS) of
        'false' ->
            Val = ecallmgr_util:maybe_sanitize_fs_value(K, V),
            Prefix = <<?CHANNEL_VAR_PREFIX, K/binary>>,
            [encode_fs_val(Prefix, Val) | Acc];
        {_, Prefix} ->
            Val = ecallmgr_util:maybe_sanitize_fs_value(K, V),
            [encode_fs_val(Prefix, Val) | Acc]
    end.

media_control_fold(K, V, Acc) ->
    [encode_fs_val(K, V) | Acc].

-spec kazoo_cavs_to_fs_vars_fold(kz_json:key(), kz_json:json_term(), iolist()) -> iolist().
kazoo_cavs_to_fs_vars_fold(K, V, Acc) ->
    {Prefix, Val} = kazoo_cav_prefix_and_value(V),
    Prefix1 = [Prefix, kz_term:to_list(K)],
    [encode_fs_val(Prefix1, Val) | Acc].

-spec kazoo_cav_prefix_and_value(kz_json:json_term()) -> {string(), string()}.
kazoo_cav_prefix_and_value(V) ->
    {Prefix, Encoded} = case kz_json:is_json_object(V) of
                            'true' -> {?JSON_APPLICATION_VAR_PREFIX, kz_json:encode(V)};
                            'false' -> {?APPLICATION_VAR_PREFIX, kz_term:to_binary(V)}
                        end,
    %% Escape all embedded single quotes and commas so that FS can consume them
    Escaped = re:replace(Encoded, <<"([,'])">>, <<"\\\\\\g1">>, ['global', {'return', 'binary'}]),
    {Prefix, kz_term:to_list(Escaped)}.

-spec kazoo_cav_prefix(kz_json:json_term()) -> kz_term:ne_binary().
kazoo_cav_prefix(V) ->
    case kz_json:is_json_object(V) of
        'true' -> <<?JSON_APPLICATION_VAR_PREFIX>>;
        'false' -> <<?APPLICATION_VAR_PREFIX>>
    end.

-spec codec_mappings(kz_term:ne_binary()) -> kz_term:ne_binary().
codec_mappings(<<"G722_32">>) ->
    <<"G7221@32000h">>;
codec_mappings(<<"G722_16">>) ->
    <<"G722:G7221@16000h">>;
codec_mappings(<<"CELT_32">>) ->
    <<"CELT@32000h">>;
codec_mappings(<<"CELT_48">>) ->
    <<"CELT@48000h">>;
codec_mappings(Codec) ->
    Codec.

%%------------------------------------------------------------------------------
%% @doc Encode the value and return a binary string with the prefix, an equal
%% sign and the value wraped in single quotes.
%% @end
%%------------------------------------------------------------------------------
-spec encode_fs_val(kz_term:text(), kz_term:text() | integer()) -> kz_term:ne_binary().
encode_fs_val(Prefix, V) ->
    list_to_binary([Prefix, "='", escape(V, $\'), "'"]).

-spec escape(kz_term:text() | integer(), char()) -> kz_term:ne_binary().
escape(V, C) ->
    iolist_to_binary([encode(A, C) || <<A>> <= kz_term:to_binary(V)]).
encode(C, C) -> [$\\, C];
encode(C, _) -> C.

-spec get_profile_params(kz_json:object() | kz_term:proplist()) -> kz_term:proplist().
get_profile_params(Props) when is_list(Props) ->
    lists:usort(lists:foldl(fun get_profile_param/2, [], Props));
get_profile_params(JObj) ->
    get_profile_params(
      kz_json:to_proplist(
        kz_json:get_json_value(<<"Custom-Profile-Vars">>, JObj, kz_json:new())
       ) ++ [{<<"Context">>, ?DEFAULT_FREESWITCH_CONTEXT}]).

-spec get_profile_param(tuple(), kz_term:proplist()) -> kz_term:proplist().
get_profile_param({<<"Endpoint-Tag-Rules">> = Key, Val}, Acc) ->
    [{Key, kz_json:encode(Val)} | Acc];
get_profile_param({Key, Val}, Acc) ->
    case lists:keyfind(Key, 1, ?CALLER_PROFILE_VARS) of
        'false' -> [{Key, ecallmgr_util:maybe_sanitize_fs_value(Key, Val)} | Acc];
        {_Key, Prefix} -> [{Prefix, ecallmgr_util:maybe_sanitize_fs_value(Key, Val)} | Acc]
    end.

-spec get_profile_vars_fold(kz_json:key(), kz_json:json_term(), iolist()) -> iolist().
get_profile_vars_fold(<<"Endpoint-Tag-Rules">> = Key, Val, Acc) ->
    [list_to_binary([Key, "='", kz_json:encode(Val), "'"]) | Acc];
get_profile_vars_fold(K, V, Acc) ->
    case lists:keyfind(K, 1, ?CALLER_PROFILE_VARS) of
        'false' ->
            Val = ecallmgr_util:maybe_sanitize_fs_value(K, V),
            [encode_fs_val(K, Val) | Acc];
        {_, Prefix} ->
            Val = ecallmgr_util:maybe_sanitize_fs_value(K, V),
            [encode_fs_val(Prefix, Val) | Acc]
    end.

-spec get_channel_params(kz_json:object() | kz_term:proplist()) -> kz_term:proplist().
get_channel_params(Props) when is_list(Props) ->
    lists:foldl(fun get_channel_params/2, [], kazoo_merge_vars(Props));
get_channel_params(JObj) ->
    get_channel_params(
      kz_json:to_proplist(
        kz_json:get_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new())
       )).

-type channel_param_kv() :: {kz_term:ne_binary(), kz_json:json_term()}.
-type channel_param_kvs() :: [channel_param_kv()].

-spec get_channel_params(channel_param_kv(), channel_param_kvs()) -> channel_param_kvs().
get_channel_params({<<"Media-Control">>, JObj}, Acc) ->
    Acc ++ kz_json:to_proplist(JObj);
get_channel_params({K, V}, Acc) ->
    [get_channel_param(K, V) | Acc].

get_channel_param(<<"Merged-Hold-Media">>, JObj) ->
    {ecallmgr_util:get_fs_key(<<"Hold-Media">>), ecallmgr_util:moh_media_path('extant', kz_log:get_callid(), JObj)};
get_channel_param(<<"Merged-Custom-Hold-Media">>, JObj) ->
    {ecallmgr_util:get_fs_key(<<"Custom-Hold-Media">>), ecallmgr_util:moh_media_path('extant', kz_log:get_callid(), JObj)};
get_channel_param(<<"Hold-Media">>=Key, Media) ->
    {ecallmgr_util:get_fs_key(Key), ecallmgr_util:moh_media_path(Media, 'extant', kz_log:get_callid(), kz_json:new())};
get_channel_param(<<"Custom-Hold-Media">>=Key, Media) ->
    {ecallmgr_util:get_fs_key(Key), ecallmgr_util:moh_media_path(Media, 'extant', kz_log:get_callid(), kz_json:new())};
get_channel_param(Key, Val) ->
    {ecallmgr_util:get_fs_key(Key), ecallmgr_util:maybe_sanitize_fs_value(Key, Val)}.

-spec get_custom_sip_headers(kz_json:object()) -> kz_json:json_proplist().
get_custom_sip_headers(JObj) ->
    kz_json:to_proplist(kz_json:get_json_value(<<"Custom-SIP-Headers">>, JObj, kz_json:new())).

-spec get_custom_routing_vars(kz_json:object()) -> kz_json:json_proplist().
get_custom_routing_vars(JObj) ->
    Props = kz_json:to_proplist(<<"Custom-Routing-Vars">>, JObj),
    get_channel_params(Props).

-spec arrange_acl_node({kz_term:ne_binary(), kz_json:object()}, orddict:orddict()) -> orddict:orddict().
arrange_acl_node({_, JObj}, Dict) ->
    AclList = kz_json:get_value(<<"network-list-name">>, JObj),
    Type = kz_json:get_value(<<"type">>, JObj),
    CIDR = kz_json:get_value(<<"cidr">>, JObj),
    Ports = kz_json:get_value(<<"ports">>, JObj),
    NodeEl = acl_node_el(Type, CIDR, Ports),
    case orddict:find(AclList, Dict) of
        {'ok', ListEl} ->
            orddict:store(AclList, prepend_child(ListEl, NodeEl), Dict);
        'error' ->
            lager:debug("creating new list xml for ~s", [AclList]),
            orddict:store(AclList, prepend_child(acl_list_el(AclList), NodeEl), Dict)
    end.

-spec hunt_context(dialplan_context()) -> kz_term:api_ne_binary().
hunt_context(#{payload:=FSJObj}) ->
    kzd_freeswitch:hunt_context(FSJObj, ?DEFAULT_FREESWITCH_CONTEXT).

-spec context(kz_json:object()) -> kz_term:api_ne_binary().
context(JObj) ->
    kz_json:get_ne_binary_value(<<"Context">>, JObj, ?DEFAULT_FREESWITCH_CONTEXT).

-spec context(kz_json:object(), dialplan_context()) -> kz_term:api_ne_binary().
context(JObj, DialplanContext) ->
    kz_json:get_ne_binary_value(<<"Context">>, JObj, hunt_context(DialplanContext)).

%%%-----------------------------------------------------------------------------
%% XML record creators and helpers
%%%-----------------------------------------------------------------------------
-spec acl_node_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value(), kz_term:api_integers()) -> kz_types:xml_el() | kz_types:xml_els().
acl_node_el(Type, CIDRs, Ports) when is_list(CIDRs) ->
    [acl_node_el(Type, CIDR, Ports) || CIDR <- CIDRs];
acl_node_el(Type, CIDR, 'undefined') ->
    #xmlElement{name='node'
               ,attributes=[xml_attrib('type', Type)
                           ,xml_attrib('cidr', CIDR)
                           ]
               };
acl_node_el(Type, CIDR, Ports) ->
    BinPorts = kz_binary:join([kz_term:to_binary(P) || P <- Ports], <<",">>),
    #xmlElement{name='node'
               ,attributes=[xml_attrib('type', Type)
                           ,xml_attrib('cidr', CIDR)
                           ,xml_attrib('ports', BinPorts)
                           ]
               }.

-spec acl_list_el(kz_types:xml_attrib_value()) -> kz_types:xml_el().
acl_list_el(Name) ->
    acl_list_el(Name, <<"deny">>).

-spec acl_list_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
acl_list_el(Name, Default) ->
    acl_list_el(Name, Default, []).

-spec acl_list_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value(), kz_types:xml_els()) -> kz_types:xml_el().
acl_list_el(Name, Default, Children) ->
    #xmlElement{name='list'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('default', Default)
                           ]
               ,content=Children
               }.

-spec network_list_el(kz_types:xml_els()) -> kz_types:xml_el().
network_list_el(ListsEls) ->
    #xmlElement{name='network-lists', content=ListsEls}.

-spec config_el(kz_term:ne_binary(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el() | kz_types:xml_els().
config_el(Name, Content) ->
    config_el(Name, <<"configuration ", (kz_term:to_binary(Name))/binary, " built by kazoo">>, Content).

-spec config_el(kz_term:ne_binary(), kz_term:ne_binary(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el() | kz_types:xml_els().
config_el(Name, Desc, #xmlElement{}=Content) ->
    config_el(Name, Desc, [Content]);
config_el(Name, Desc, Content) ->
    #xmlElement{name='configuration'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('description', Desc)
                           ]
               ,content=Content
               }.

-spec channel_el(kz_term:api_binary(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el() | kz_types:xml_els().
channel_el('undefined', Content) -> Content;
channel_el(UUID, Content) ->
    channel_el(UUID, <<"channel ", (kz_term:to_binary(UUID))/binary, " tracked by kazoo">>, Content).

-spec channel_el(kz_term:ne_binary(), kz_term:ne_binary(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el().
channel_el(UUID, Desc, #xmlElement{}=Content) ->
    channel_el(UUID, Desc, [Content]);
channel_el(UUID, Desc, Content) ->
    #xmlElement{name='channel'
               ,attributes=[xml_attrib('uuid', UUID)
                           ,xml_attrib('description', Desc)
                           ]
               ,content=Content
               }.

-spec section_el(kz_types:xml_attrib_value(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el().
section_el(Name, #xmlElement{}=Content) ->
    section_el(Name, [Content]);
section_el(Name, Content) ->
    #xmlElement{name='section'
               ,attributes=[xml_attrib('name', Name)]
               ,content=Content
               }.

-spec section_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el().
section_el(Name, Desc, #xmlElement{}=Content) ->
    section_el(Name, Desc, [Content]);
section_el(Name, Desc, Content) ->
    #xmlElement{name='section'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('description', Desc)
                           ]
               ,content=Content
               }.

-spec domain_el(kz_types:xml_attrib_value(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el().
domain_el(Name, Child) when not is_list(Child) ->
    domain_el(Name, [Child]);
domain_el(Name, Children) ->
    #xmlElement{name='domain'
               ,attributes=[xml_attrib('name', Name)]
               ,content=Children
               }.

group_el(Props, Children) when is_list(Props) ->
    #xmlElement{name='group'
               ,attributes=[xml_attrib(K, V)
                            || {K, V} <- props:unique(
                                           props:filter_undefined(Props)
                                          )
                           ]
               ,content=Children
               };
group_el(Name, Children) ->
    #xmlElement{name='group'
               ,content=Children
               ,attributes=[xml_attrib('name', Name)]
               }.

groups_el(Children) ->
    #xmlElement{name='groups'
               ,content=Children
               }.


users_el(Children) ->
    #xmlElement{name='users'
               ,content=Children
               }.

%% -spec user_ptr_el(kz_types:xml_attrib_value()) -> kz_types:xml_el().
%% user_ptr_el(Id) ->
%%     #xmlElement{name='user'
%%                ,attributes=[xml_attrib('id', Id)
%%                            ,xml_attrib('type', <<"pointer">>)
%%                            ]
%%                }.

-spec user_el(kz_types:xml_attrib_value() | kz_term:proplist(), kz_types:xml_els()) -> kz_types:xml_el().
user_el(Id, Children) when not is_list(Id) ->
    user_el(user_el_default_props(Id), Children);
user_el(Props, Children) ->
    #xmlElement{name='user'
               ,attributes=[xml_attrib(K, V)
                            || {K, V} <- props:unique(
                                           props:filter_undefined(Props)
                                          )
                           ]
               ,content=[C || C <- Children, C =/= 'undefined']
               }.

-spec user_el_props(kz_term:api_ne_binary(), kz_term:ne_binary(), kz_term:api_integer()) -> kz_term:proplist().
user_el_props(Number, Username, Expires) ->
    user_el_props(Number, Username, Expires, 'undefined').

-spec user_el_props(kz_term:api_ne_binary(), kz_term:ne_binary(), kz_term:api_integer(), kz_term:api_ne_binary()) -> kz_term:proplist().
user_el_props(Number, Username, Expires, Revision) ->
    [{'id', Username}
    ,{'revision', Revision}
    ,{'number-alias', Number}
    ,{'cacheable', Expires}
    ].

-spec user_el_default_props(kz_types:xml_attrib_value()) -> kz_term:proplist().
user_el_default_props(Id) ->
    [{'id', Id}].

-spec chat_user_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
chat_user_el(Name, Commands) ->
    #xmlElement{name='user'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('commands', Commands)
                           ]
               }.

-spec params_el(kz_types:xml_els()) -> kz_types:xml_el().
params_el(Children) ->
    #xmlElement{name='params'
               ,content=Children
               }.

-spec param_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
param_el(Name, Value) ->
    #xmlElement{name='param'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('value', Value)
                           ]
               }.

-spec maybe_param_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el() | 'undefined'.
maybe_param_el(Name, Value) ->
    case kz_term:is_empty(Value) of
        'true' -> 'undefined';
        'false' -> param_el(Name, Value)
    end.

profile_el(Name, Children) ->
    #xmlElement{name='profile'
               ,content=Children
               ,attributes=[xml_attrib('name', Name)]
               }.

profiles_el(Children) ->
    #xmlElement{name='profiles'
               ,content=Children
               }.

control_el(Action, Digits) ->
    #xmlElement{name='control'
               ,attributes=[xml_attrib('action', Action)
                           ,xml_attrib('digits', Digits)
                           ]
               }.

control_el(Action, Digits, 'undefined') -> control_el(Action, Digits);
control_el(Action, Digits, Data) ->
    #xmlElement{name='control'
               ,attributes=[xml_attrib('action', Action)
                           ,xml_attrib('digits', Digits)
                           ,xml_attrib('data', Data)
                           ]
               }.

advertise_el(Rooms) ->
    #xmlElement{name='advertise'
               ,content=Rooms
               }.

caller_controls_el(Groups) ->
    #xmlElement{name='caller-controls'
               ,content=Groups
               }.

chat_permissions_el(Profiles) ->
    #xmlElement{name='chat-permissions'
               ,content=Profiles
               }.

-spec variables_el(kz_types:xml_els()) -> kz_types:xml_el().
variables_el(Children) ->
    #xmlElement{name='variables'
               ,content=Children
               }.

-spec variables_el(atom(), kz_types:xml_els()) -> kz_types:xml_el().
variables_el(Name, Children) ->
    #xmlElement{name=Name
               ,content=Children
               }.

-spec variable_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
variable_el(Name, Value) ->
    #xmlElement{name='variable'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('value', Value)
                           ]
               }.

-spec registration_headers_el(kz_types:xml_els()) -> kz_types:xml_el().
registration_headers_el(Children) ->
    #xmlElement{name='registration-headers'
               ,content=Children
               }.

-spec header_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
header_el(Name, Value) ->
    #xmlElement{name='header'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('value', Value)
                           ]
               }.

-spec context_el(kz_types:xml_attrib_value(), kz_types:xml_els()) -> kz_types:xml_el().
context_el(Name, Children) ->
    #xmlElement{name='context'
               ,attributes=[xml_attrib('name', Name)]
               ,content=Children
               }.

-spec named_el(atom(), kz_types:xml_els()) -> kz_types:xml_el().
named_el(Name, Children) ->
    #xmlElement{name=Name
               ,content=Children
               }.

-spec extension_el(kz_types:xml_els()) -> kz_types:xml_el().
extension_el(Children) ->
    #xmlElement{name='extension'
               ,content=Children
               }.

-spec extension_el(kz_types:xml_attrib_value(), kz_types:xml_els()) -> kz_types:xml_el().
extension_el(Name, Children) ->
    extension_el(Name, 'undefined', Children).

-spec extension_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value() | 'undefined', kz_types:xml_els()) -> kz_types:xml_el().
extension_el(Name, 'undefined', Children) ->
    #xmlElement{name='extension'
               ,attributes=[xml_attrib('name', Name)]
               ,content=[Child || Child <- Children, Child =/= 'undefined']
               };
extension_el(Name, Continue, Children) ->
    #xmlElement{name='extension'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('continue', kz_term:is_true(Continue))
                           ]
               ,content=[Child || Child <- Children, Child =/= 'undefined']
               }.

-spec condition_el(kz_types:xml_el() | kz_types:xml_els() | 'undefined') -> kz_types:xml_el().
condition_el(Child) when not is_list(Child) ->
    condition_el([Child]);
condition_el(Children) ->
    #xmlElement{name='condition'
               ,content=[Child || Child <- Children, Child =/= 'undefined']
               }.

-spec condition_el(kz_types:xml_el() | kz_types:xml_els() | 'undefined', kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
condition_el(Child, Field, Expression) when not is_list(Child) ->
    condition_el([Child], Field, Expression);
condition_el(Children, Field, Expression) ->
    #xmlElement{name='condition'
               ,content=[Child || Child <- Children, Child =/= 'undefined']
               ,attributes=[xml_attrib('field', Field)
                           ,xml_attrib('expression', Expression)
                           ]
               }.

-spec action_el(kz_types:xml_attrib_value()) -> kz_types:xml_el().
action_el(App) ->
    #xmlElement{name='action'
               ,attributes=[xml_attrib('application', App)]
               }.

-spec action_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
action_el(App, Data) ->
    #xmlElement{name='action'
               ,attributes=[xml_attrib('application', App)
                           ,xml_attrib('data', Data)
                           ]
               }.

-spec action_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value() | 'undefined', boolean()) -> kz_types:xml_el().
action_el(App, 'undefined', Inline) ->
    #xmlElement{name='action'
               ,attributes=[xml_attrib('application', App)
                           ,xml_attrib('inline', kz_term:to_binary(Inline))
                           ]
               };
action_el(App, Data, Inline) ->
    #xmlElement{name='action'
               ,attributes=[xml_attrib('application', App)
                           ,xml_attrib('data', Data)
                           ,xml_attrib('inline', kz_term:to_binary(Inline))
                           ]
               }.

-spec anti_action_el(kz_types:xml_attrib_value()) -> kz_types:xml_el().
anti_action_el(App) ->
    #xmlElement{name='anti-action'
               ,attributes=[xml_attrib('application', App)]
               }.

-spec anti_action_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
anti_action_el(App, Data) ->
    #xmlElement{name='anti-action'
               ,attributes=[xml_attrib('application', App)
                           ,xml_attrib('data', Data)
                           ]
               }.

-spec anti_action_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value(), boolean()) -> kz_types:xml_el().
anti_action_el(App, Data, Inline) ->
    #xmlElement{name='anti-action'
               ,attributes=[xml_attrib('application', App)
                           ,xml_attrib('data', Data)
                           ,xml_attrib('inline', kz_term:to_binary(Inline))
                           ]
               }.

-spec result_el(kz_types:xml_attrib_value()) -> kz_types:xml_el().
result_el(Status) ->
    #xmlElement{name='result'
               ,attributes=[xml_attrib('status', Status)]
               }.

room_el(Name, Status) ->
    #xmlElement{name='room'
               ,attributes=[xml_attrib('name', Name)
                           ,xml_attrib('status', Status)
                           ]
               }.

-spec prepend_child(kz_types:xml_el(), kz_types:xml_el() | kz_types:xml_els()) -> kz_types:xml_el().
prepend_child(#xmlElement{}=El, Children) when is_list(Children) ->
    lists:foldl(fun(C, #xmlElement{content=Contents}=E) ->
                        E#xmlElement{content=[C|Contents]}
                end, El, Children);
prepend_child(#xmlElement{content=Contents}=El, Child) ->
    El#xmlElement{content=[Child|Contents]}.

-spec xml_attrib(kz_types:xml_attrib_name(), kz_types:xml_attrib_value()) -> kz_types:xml_attrib().
xml_attrib(Name, Value) when is_atom(Name) ->
    #xmlAttribute{name=Name, value=kz_term:to_list(Value)}.

-spec sofia_conf_xml(kz_json:object()) -> {'ok', iolist()}.
sofia_conf_xml(JObj) ->
    SettingsEl = sofia_global_settings_el(kz_json:get_json_value(<<"settings">>, JObj)),
    ProfilesEl = sofia_profiles_el(kz_json:get_json_value(<<"profiles">>, JObj)),

    ConfigEl = config_el(<<"sofia.conf">>, [SettingsEl, ProfilesEl]),

    SectionEl = section_el(<<"configuration">>, ConfigEl),

    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

sofia_global_settings_el('undefined') ->
    #xmlElement{name='global_settings'};
sofia_global_settings_el(Settings) ->
    #xmlElement{name='global_settings', content=sofia_settings_el(Settings)}.

sofia_profiles_el('undefined') ->
    #xmlElement{name='profiles'};
sofia_profiles_el(JObj) ->
    Content = lists:foldl(sofia_profiles_fold_fun(JObj), [], kz_json:get_keys(JObj)),
    #xmlElement{name='profiles', content=Content}.

sofia_profiles_fold_fun(JObj) ->
    fun(Key, Xml) ->
            Profile = kz_json:get_json_value(Key, JObj),
            [#xmlElement{name='profile'
                        ,attributes=[xml_attrib('name', Key)]
                        ,content=sofia_profile_el(Profile)
                        }
            | Xml
            ]
    end.

sofia_profile_el(JObj) ->
    Routines = [{<<"Settings">>, fun sofia_profile_settings/1}
               ,{<<"Gateways">>, fun sofia_profile_gateways/1}
               ],
    lists:foldr(sofia_profile_fold_fun(JObj), [], Routines).

sofia_profile_fold_fun(JObj) ->
    fun({Key, Fun}, Acc) ->
            case kz_json:get_json_value(Key, JObj) of
                'undefined' -> Acc;
                Value -> [Fun(Value) | Acc]
            end
    end.

sofia_profile_settings(Settings) ->
    #xmlElement{name='settings', content=sofia_settings_el(Settings)}.

sofia_profile_gateways(Gateways) ->
    #xmlElement{name='gateways', content=sofia_gateways_el(Gateways)}.

sofia_settings_el(JObj) ->
    lists:foldl(sofia_settings_el_fun(JObj), [], kz_json:get_keys(JObj)).

sofia_settings_el_fun(JObj) ->
    fun(Key, Xml) ->
            Name = kz_term:to_lower_binary(Key),
            case kz_json:get_value(Key, JObj) of
                'undefined' -> Xml;
                Values when is_list(Values) ->
                    lists:foldl(sofia_setting_el_fun(Name), Xml, Values);
                Value ->
                    sofia_setting_el(Name, Value, Xml)
            end
    end.

sofia_setting_el_fun(Name) ->
    fun(Value, Acc) ->
            sofia_setting_el(Name, Value, Acc)
    end.

sofia_setting_el(Name, Value, Xml) ->
    [param_el(Name, kz_term:to_binary(Value)) | Xml].

sofia_gateways_el(JObj) ->
    lists:foldl(fun(Key, Xml) ->
                        Gateway = kz_json:get_value(Key, JObj),
                        [#xmlElement{name='gateway'
                                    ,attributes=[xml_attrib('name', Key)]
                                    ,content=sofia_gateway_el(Gateway)
                                    }
                        | Xml
                        ]
                end, [], kz_json:get_keys(JObj)).

sofia_gateway_el(JObj) ->
    lists:foldl(fun(<<"Variables">>, Xml) ->
                        Variables = kz_json:get_value(<<"Variables">>, JObj),
                        [#xmlElement{name='variables'
                                    ,content=sofia_gateway_vars_el(Variables)
                                    }
                        | Xml
                        ];
                   (Key, Xml) ->
                        Value = kz_json:get_value(Key, JObj),
                        Name = kz_term:to_lower_binary(Key),
                        [#xmlElement{name='param'
                                    ,attributes=[xml_attrib('name', Name)
                                                ,xml_attrib('value', Value)
                                                ]
                                    }
                        | Xml
                        ]
                end, [], kz_json:get_keys(JObj)).

sofia_gateway_vars_el(JObj) ->
    lists:foldl(fun(Key, Xml) ->
                        Value = kz_json:get_value(Key, JObj),
                        [#xmlElement{name='variable'
                                    ,attributes=[xml_attrib('name', Key)
                                                ,xml_attrib('value', Value)
                                                ,xml_attrib('direction', "inbound")
                                                ]
                                    }
                        | Xml
                        ]
                end, [], kz_json:get_keys(JObj)).

-spec event_filters_resp_xml(kz_term:ne_binaries()) -> {'ok', iolist()}.
event_filters_resp_xml(Headers) ->
    EventFiltersEl = event_filters_xml(Headers),
    ConfigurationEl = config_el(<<"kazoo.conf">>, <<"Built by Kazoo">>, [EventFiltersEl]),
    SectionEl = section_el(<<"configuration">>, ConfigurationEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

event_filters_xml(Headers) ->
    EventFiltersEls = [event_filter_el(Header) || Header <- Headers],
    event_filters_el(EventFiltersEls).

event_filter_el(Header) ->
    #xmlElement{name='header'
               ,attributes=[xml_attrib('name', Header)]
               }.

event_filters_el(Filters) ->
    #xmlElement{name='event-filter'
               ,content=Filters
               ,attributes=[xml_attrib('type', <<"whitelist">>)]
               }.

-spec route_resp_park_xml(kz_json:object(), dialplan_context()) -> kz_types:xml_els().
route_resp_park_xml(JObj, DialplanContext) ->
    Exten = [route_resp_progress(JObj)
            ,route_resp_log_winning_node()
            ,route_resp_set_winning_node()
            ,route_resp_bridge_id()
            ,route_resp_set_control_info(DialplanContext)
            ,route_resp_ringback(JObj)
            ,route_resp_transfer_ringback(JObj)
            ,maybe_start_dtmf_action(DialplanContext)
            ,route_resp_pre_park_action(JObj)
            ,route_resp_ccvs(JObj)
            ,route_resp_cavs(JObj)
            ,unset_custom_sip_headers()
            ,route_resp_set_originating_proxy(DialplanContext)
            ,route_resp_fire_route_win(JObj, DialplanContext)
            ,route_resp_channel_update(JObj, DialplanContext)
            ,route_resp_park()
            ],
    [E || E <- Exten, E =/= 'undefined'].

-spec route_resp_set_control_info(dialplan_context()) -> kz_types:xml_el().
route_resp_set_control_info(#{control_q := ControlQ
                             ,control_p := ControlP
                             ,fetch_id := FetchId
                             }
                           ) ->
    App = <<"kz_multiset_encoded">>,
    NodeBin = kz_term:to_binary(node()),
    Arg = list_to_binary(["^^;Call-Control-Queue="
                         ,ControlQ
                         ,";Call-Control-PID="
                         ,kz_term:to_binary(ControlP)
                         ,";ecallmgr_Ecallmgr-Node="
                         ,NodeBin
                         ,";Call-Control-Node="
                         ,NodeBin
                         ,";Fetch-UUID="
                         ,FetchId
                         ]),
    action_el(App, no_channel_data_updates(Arg), 'true').

directory_resp_domain(Endpoint, JObj) ->
    case kz_json:get_ne_binary_value(<<"Requested-Domain-Name">>, JObj) of
        'undefined' -> kz_json:get_ne_binary_value(<<"Domain-Name">>, Endpoint);
        Domain -> Domain
    end.

directory_resp_user_id(Endpoint, JObj) ->
    case kz_json:get_ne_binary_value(<<"Requested-User-ID">>, JObj) of
        'undefined' -> kz_json:get_ne_binary_value(<<"User-ID">>, Endpoint);
        UserID -> UserID
    end.

directory_resp_group_id(Endpoint, JObj) ->
    case kz_json:get_ne_binary_value(<<"Requested-Group-ID">>, JObj) of
        'undefined' -> kz_json:get_ne_binary_value(<<"Group-ID">>, Endpoint);
        GroupID -> GroupID
    end.

dial_string(Endpoint) ->
    kz_json:get_ne_binary_value(<<"Endpoint-Dial-String">>, Endpoint).

route_uri(Endpoint) ->
    kz_json:get_ne_binary_value(<<"SIP-Proxy-Route-URI">>, Endpoint).

route_uri_el(Endpoint) ->
    case route_uri(Endpoint) of
        'undefined' -> 'undefined';
        Route -> variable_el(<<"sip_route_uri">>, Route)
    end.

route_uri_els(Endpoint) ->
    case route_uri_el(Endpoint) of
        'undefined' -> [];
        RouteEl -> [RouteEl]
    end.

-spec directory_resp_endpoint_xml(atom(), kz_json:object(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_endpoint_xml(Node, Endpoint, JObj) ->
    Type = kz_json:get_ne_binary_value(<<"Endpoint-Type">>, Endpoint, <<"device">>),
    directory_resp_endpoint_xml(Type, Node, Endpoint, JObj).

-spec directory_resp_endpoint_xml(binary(), atom(), kz_json:object(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_endpoint_xml(<<"resource">>, Node, Endpoint, JObj) ->
    directory_resp_resource_xml(Node, Endpoint, JObj);
directory_resp_endpoint_xml(<<"group">>, Node, Endpoint, JObj) ->
    directory_resp_group_ep_xml(Node, Endpoint, JObj);
directory_resp_endpoint_xml(<<"user">>, Node, Endpoint, JObj) ->
    directory_resp_user_xml(Node, Endpoint, JObj);
directory_resp_endpoint_xml(<<"device">>, Node, Endpoint, JObj) ->
    directory_resp_device_xml(Node, Endpoint, JObj);
directory_resp_endpoint_xml(<<"sys_info">>, Node, Endpoint, JObj) ->
    directory_resp_device_xml(Node, Endpoint, JObj).

-spec directory_resp_resource_xml(atom(), kz_json:object(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_resource_xml(_Node, Endpoint, JObj) ->
    DomainName = directory_resp_domain(Endpoint, JObj),
    UserId = directory_resp_user_id(Endpoint, JObj),
    Revision = kz_json:get_ne_binary_value(<<"Revision">>, Endpoint),

    ProfileParams = get_profile_params(Endpoint),
    SIPHeaders = get_custom_sip_headers(Endpoint),
    VariableEls = get_directory_variables(Endpoint),
    HeaderEls = [variable_el(K, V) || {K, V} <- SIPHeaders],
    VariablesEl = variables_el(VariableEls ++ HeaderEls),
    ProfileEls = [variable_el(K, V) || {K, V} <- ProfileParams],
    ProfileVariablesEl = variables_el('profile-variables', ProfileEls),

    Expires = kz_json:get_integer_value(<<"Expires">>, Endpoint),
    UserProps = user_el_props(undefined, UserId, Expires, Revision),

    UserEl = user_el(UserProps, [VariablesEl, ProfileVariablesEl]),
    DomainEl = domain_el(DomainName, UserEl),
    SectionEl = section_el(<<"directory">>, DomainEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec directory_resp_device_xml(atom(), kz_json:object(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_device_xml(_Node, Endpoint, JObj) ->
    DomainName = directory_resp_domain(Endpoint, JObj),
    UserId = directory_resp_user_id(Endpoint, JObj),
    Revision = kz_json:get_ne_binary_value(<<"Revision">>, Endpoint),

    ProfileParams = get_profile_params(Endpoint),
    VariableEls = get_directory_variables(Endpoint),
    ProxyPathEls = route_uri_els(Endpoint),

    VariablesEl = variables_el(VariableEls ++ ProxyPathEls),

    Number = kz_json:get_value([<<"Custom-SIP-Headers">>,<<"P-Kazoo-Primary-Number">>], Endpoint),
    Expires = kz_json:get_integer_value(<<"Expires">>, Endpoint),
    UserProps = user_el_props(Number, UserId, Expires, Revision),

    ProfileEls = [variable_el(K, V) || {K, V} <- ProfileParams],
    ProfileVariablesEl = variables_el('profile-variables', ProfileEls),

    CRVs = get_custom_routing_vars(Endpoint),
    CRVsEl = [param_el(<<"dial-var-", K/binary>>, V) || {K, V} <- CRVs],
    SIPHeaders = get_custom_sip_headers(Endpoint),
    SIPHeadersEl = [param_el(<<"dial-var-sip_h_", K/binary>>, V) || {K, V} <- SIPHeaders],
    Params = [{<<"endpoint-dial-string">>, dial_string(Endpoint)}
             ,{<<"endpoint-separator">>, kz_endpoint_separator()}
             ,{<<"jsonrpc-allowed-methods">>, <<"verto">>}
             ,{<<"jsonrpc-allowed-event-channels">>, <<"conference">>}
             ],
    ParamsEl = [param_el(K,V) || {K,V} <- Params],
    ParamsEls = params_el(ParamsEl ++ SIPHeadersEl ++ CRVsEl),

    UserEl = user_el(UserProps, [VariablesEl, ProfileVariablesEl, ParamsEls, callfwd_el(Endpoint), failover_el(Endpoint)]),
    DomainEl = domain_el(DomainName, UserEl),
    SectionEl = section_el(<<"directory">>, DomainEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec directory_resp_user_xml(atom(), kz_json:object(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_user_xml(_Node, Endpoint, JObj) ->
    DomainName = directory_resp_domain(Endpoint, JObj),
    UserId = directory_resp_user_id(Endpoint, JObj),
    Revision = kz_json:get_ne_binary_value(<<"Revision">>, Endpoint),

    ProfileParams = get_profile_params(Endpoint),
    VariableEls = get_directory_variables(Endpoint),
    VariablesEl = variables_el(VariableEls),
    ProfileEls = [variable_el(K, V) || {K, V} <- ProfileParams],
    ProfileVariablesEl = variables_el('profile-variables', ProfileEls),

    Expires = kz_json:get_integer_value(<<"Expires">>, Endpoint),
    UserProps = user_el_props(undefined, UserId, Expires, Revision),

    Params = [{<<"endpoint-dial-string">>,  dial_string(Endpoint)}
             ,{<<"endpoint-separator">>, kz_endpoint_separator()}
             ,{<<"jsonrpc-allowed-methods">>, <<"verto">>}
             ,{<<"jsonrpc-allowed-event-channels">>, <<"conference">>}
             ],
    ParamsEl = [param_el(K,V) || {K,V} <- Params],
    SIPHeaders = get_custom_sip_headers(Endpoint),
    SIPHeadersEl = [param_el(<<"dial-var-sip_h_", K/binary>>, V) || {K, V} <- SIPHeaders],
    CRVs = get_custom_routing_vars(Endpoint),
    CRVsEl = [param_el(<<"dial-var-", K/binary>>, V) || {K, V} <- CRVs],

    ParamsEls = params_el(ParamsEl ++ SIPHeadersEl ++ CRVsEl),

    UserEl = user_el(UserProps, [VariablesEl, ProfileVariablesEl, ParamsEls, callfwd_el(Endpoint), failover_el(Endpoint)]),
    DomainEl = domain_el(DomainName, UserEl),
    SectionEl = section_el(<<"directory">>, DomainEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec directory_resp_group_ep_xml(atom(), kz_json:object(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_group_ep_xml(_Node, Endpoint, JObj) ->
    DomainName = directory_resp_domain(Endpoint, JObj),
    GroupId = directory_resp_user_id(Endpoint, JObj),
    Revision = kz_json:get_ne_binary_value(<<"Revision">>, Endpoint),

    Expires = kz_json:get_integer_value(<<"Expires">>, Endpoint),
    GroupProps = user_el_props(undefined, GroupId, Expires, Revision),

    VariableEls = get_directory_variables(Endpoint),
    Members = kz_json:get_list_value(<<"Members">>, Endpoint, []),
    Dial = lists:foldr(fun(EP, Acc) ->
                               Id = kz_json:get_ne_binary_value(<<"id">>, EP, <<"error">>),
                               Delay = kz_json:get_integer_value(<<"delay">>, EP, 0),
                               Timeout = kz_json:get_integer_value(<<"timeout">>, EP, 120),
                               D = list_to_binary(["["
                                                  ,"leg_delay_start=", kz_term:to_binary(Delay)
                                                  ,",leg_timeout=", kz_term:to_binary(Timeout)
                                                  ,"]",
                                                   "kz/", Id, "@", DomainName
                                                  ]),
                               [D | Acc]
                       end, [], Members),
    Params = [param_el(<<"dial-string">>, kz_binary:join(Dial, ?SEPARATOR_ENTERPRISE))],
    GroupEl = user_el(GroupProps, [params_el(Params), variables_el(VariableEls)]),
    DomainEl = domain_el(DomainName, GroupEl),
    SectionEl = section_el(<<"directory">>, DomainEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec directory_resp_group_xml(atom(), kz_json:object(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_group_xml(_Node, Endpoint, JObj) ->
    DomainName = directory_resp_domain(Endpoint, JObj),
    GroupId = directory_resp_group_id(Endpoint, JObj),
    Revision = kz_json:get_ne_binary_value(<<"Revision">>, Endpoint),

    Expires = kz_json:get_integer_value(<<"Expires">>, Endpoint),
    GroupProps = [{<<"name">>, GroupId}
                 | user_el_props(undefined, GroupId, Expires, Revision)
                 ],

    Members = kz_json:get_json_value(<<"Members">>, Endpoint, kz_json:new()),
    MembersEl = kz_json:foldr(fun fold_user_el/3, [], Members),
    VariableEls = get_directory_variables(Endpoint),

    GroupEl = group_el(GroupProps, [users_el(MembersEl),variables_el(VariableEls)]),

    DomainEl = domain_el(DomainName, [groups_el([GroupEl])]),
    SectionEl = section_el(<<"directory">>, DomainEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec fold_user_el(kz_json:key(), kz_json:json_term(), [kz_types:xml_el()]) -> [kz_types:xml_el()].
fold_user_el(Key, _J, Acc) ->
    UserProps = user_el_default_props(Key),
    Param = param_el(<<"dial-string">>, <<>>),
    [user_el(UserProps, [params_el([Param])]) | Acc].

-define(CALLFWD_FILTER, [<<"Call-Forward">>
                        ,<<"Is-Failover">>
                        ,<<"Is-Substitute">>
                        ,<<"Direct-Calls-Only">>
                        ,<<"Failover-Reasons">>
                        ,<<"Dial-String">>
                        ,<<"Request-URI">>
                        ]).

callfwd_el(Endpoint) ->
    case callfwd_properties(Endpoint) of
        [] -> 'undefined';
        Props -> variables_el('call-forward', [variable_el(K, callfwd_property(K, V)) || {K, V} <- Props])
    end.

-spec callfwd_property(kz_term:ne_binary(), kz_json:json_term()) -> binary().
callfwd_property(<<"Failover-Reasons">>, Value)
  when is_list(Value) ->
    kz_binary:join(Value, <<"|">>);
callfwd_property(_, Value) -> kz_term:to_binary(Value).

callfwd_properties(Endpoint) ->
    case kz_json:get_json_value(<<"CallForward">>, Endpoint) of
        'undefined' -> [];
        CallForward ->
            DialString = call_forward_dial_string(CallForward),
            URI = kz_json:get_ne_binary_value(<<"Call-Forward-Request-URI">>, CallForward),
            Props = kz_json:to_proplist(<<"Custom-Channel-Vars">>, CallForward),
            filter_call_fwd_props([{<<"Dial-String">>, DialString}
                                  ,{<<"Request-URI">>, URI}
                                  | Props
                                  ])
    end.

call_forward_dial_string(CallForward) ->
    URI = kz_json:get_ne_binary_value(<<"Call-Forward-Request-URI">>, CallForward),
    Vars = channel_vars(CallForward),
    list_to_binary(["[^^!", kz_binary:join(Vars, <<"!">>), "]loopback/", URI]).

filter_call_fwd_prop({<<"Call-Forward-", _/binary>>, _}) -> true;
filter_call_fwd_prop({Key, _}) ->
    lists:member(Key, ?CALLFWD_FILTER).

filter_call_fwd_props(Props) ->
    lists:filter(fun filter_call_fwd_prop/1, Props).

failover_el(Endpoint) ->
    case failover_properties(Endpoint) of
        [] -> 'undefined';
        Props -> variables_el('failover', [variable_el(K, callfwd_property(K, V)) || {K, V} <- Props])
    end.

failover_properties(Endpoint) ->
    case kz_json:get_json_value(<<"Failover">>, Endpoint) of
        'undefined' -> [];
        Failover ->
            DialString = call_forward_dial_string(Failover),
            URI = kz_json:get_ne_binary_value(<<"Call-Forward-Request-URI">>, Failover),
            Props = kz_json:to_proplist(<<"Custom-Channel-Vars">>, Failover),
            filter_call_fwd_props([{<<"Dial-String">>, DialString}
                                  ,{<<"Request-URI">>, URI}
                                  | Props
                                  ])
    end.

-spec location_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
location_el(Id, Value) ->
    #xmlElement{name='location'
               ,attributes=[xml_attrib('id', Id)
                           ,xml_attrib('value', Value)
                           ]
               }.

-spec directory_resp_location_xml(kz_term:ne_binary(), kz_term:proplist(), kz_json:object()) -> {'ok', iolist()}.
directory_resp_location_xml(ProxyPath, Props, JObj) ->
    %% TODO
    %% sipinterface_1 => compute from Proxy-IP / Proxy-Port & networks
    Id = kzd_fetch:fetch_key_value(JObj),
    Location = directory_resp_location(Id, ProxyPath, Props),
    LocationEl = location_el(Id, Location),
    SectionEl = section_el(<<"directory">>,  LocationEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec directory_resp_location_xml([{kz_term:ne_binary(), kz_term:proplist()}], kz_json:object()) -> {'ok', iolist()}.
directory_resp_location_xml(Metas, JObj) ->
    Id = kzd_fetch:fetch_key_value(JObj),
    Location = kz_binary:join([directory_resp_location(Id, ProxyPath, Props) || {ProxyPath, Props} <- Metas], <<",">>),
    LocationEl = location_el(Id, Location),
    SectionEl = section_el(<<"directory">>,  LocationEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

directory_resp_location(Id, ProxyPath, Props) ->
    SIPInterface = ?DEFAULT_FS_PROFILE,
    Params = get_channel_params(props:set_value(<<"Proxy-URI">>, ProxyPath, Props)),
    Vars = directory_resp_location_vars(Params),
    list_to_binary(["[^^!", kz_binary:join(Vars, <<"!">>), "]", "sofia", "/", SIPInterface, "/", Id]).

directory_resp_location_vars(Props) ->
    [encode_fs_val(K, V) || {K, V} <-  Props].

-spec prompt_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
prompt_el(Id, Value) ->
    #xmlElement{name='prompt'
               ,attributes=[xml_attrib('path', Id)
                           ,xml_attrib('value', Value)
                           ]
               }.

-spec prompt_resp_xml(kz_term:ne_binary(), kz_json:object()) -> {'ok', iolist()}.
prompt_resp_xml(Url, JObj) ->
    Id = kzd_fetch:fetch_key_value(JObj),
    LocationEl = prompt_el(Id, Url),
    SectionEl = section_el(<<"configuration">>,  LocationEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

kz_endpoint_separator() ->
    ?SEPARATOR_SIMULTANEOUS.

-define(EXCLUDE_VARIABLE_GROUPS, []).

-define(DIRECTORY_VARIABLES_KEYS, [<<"Custom-Channel-Vars">>
                                  ,<<"Custom-Application-Vars">>
                                  ,<<"Codecs">>
                                  ]).

-spec get_directory_variables(kz_json:object()) -> kz_types:xml_els().
get_directory_variables(JObj) ->
    Fun = fun(Key, Acc) -> get_directory_variables(Key, JObj, Acc) end,
    lists:foldl(Fun, [], ?DIRECTORY_VARIABLES_KEYS).

-spec get_directory_variables(kz_term:ne_binary(), kz_json:object(), kz_types:xml_els()) -> kz_types:xml_els().
get_directory_variables(<<"Codecs">>, Endpoint, Acc) ->
    codecs_els(Endpoint) ++ Acc;
get_directory_variables(<<"Custom-Application-Vars">> = Key, Endpoint, Acc) ->
    cavs_els(kz_json:get_json_value(Key, Endpoint)) ++ Acc;
get_directory_variables(ObjectKey, JObj, Acc) ->
    Props = kz_json:to_proplist(ObjectKey, JObj),
    get_directory_variables(kazoo_merge_vars(Props), Acc).

-spec get_directory_variables(kz_term:api_terms(), kz_types:xml_els()) -> kz_types:xml_els().
get_directory_variables(Props, Acc)
  when is_list(Props) ->
    Fun = fun({K, V}, Acc1) ->
                  [get_directory_variables_fold(K, V) | Acc1]
          end,
    lists:foldl(Fun, Acc, Props);
get_directory_variables(JObj, Acc) ->
    Props = kz_json:to_proplist(JObj),
    get_directory_variables(Props, Acc).

-spec get_directory_variables_fold(kz_json:key(), kz_json:json_term()) -> kz_types:xml_el().
get_directory_variables_fold(<<"Merged-", _/binary>> = Key, Value) ->
    get_directory_variable(Key, Value);
get_directory_variables_fold(Key, Value) ->
    case kz_json:is_json_object(Value)
        andalso not lists:member(Key, ?EXCLUDE_VARIABLE_GROUPS)
    of
        'true' ->
            K = kz_term:to_atom(kz_json:normalize_key(Key), 'true'),
            variables_el(K, get_directory_variables(Value, []));
        'false' ->
            get_directory_variable(Key, Value)
    end.

-spec get_directory_variable({kz_json:key(), kz_json:json_term()}) -> kz_types:xml_el().
get_directory_variable({Key, Value}) ->
    variable_el(Key, Value).

-spec get_directory_variable(kz_json:key(), kz_json:json_term()) -> kz_types:xml_el().
get_directory_variable(Key, Value) ->
    get_directory_variable(get_channel_param(Key, Value)).

-spec codecs_els(kz_json:object()) -> kz_types:xml_els().
codecs_els(Endpoint) ->
    case kz_json:get_ne_binaries(<<"Codecs">>, Endpoint, []) of
        [] -> [];
        Cs -> [codecs_el(Cs)]
    end.

-spec codecs_el(kz_term:ne_binaries()) -> kz_types:xml_el().
codecs_el(Codecs) ->
    CodecsMap = [codec_mappings(Codec) || Codec <- Codecs, not kz_term:is_empty(Codec)],
    variable_el(<<"absolute_codec_string">> , kz_binary:join(CodecsMap, <<",">>)).

cavs_els('undefined') -> [];
cavs_els(CAVs) ->
    kz_json:foldl(fun cav_el/3, [], CAVs).

cav_el(Key, Value, Acc) ->
    Name = list_to_binary([kazoo_cav_prefix(Value), Key]),
    [get_directory_variable({Name, ecallmgr_util:maybe_sanitize_fs_value(Key, Value)}) | Acc].

-spec encode_sip_diversions(kz_term:ne_binaries()) -> kz_term:ne_binary().
encode_sip_diversions(Diversions) ->
    case kz_app_config:is_true(?APP, <<"send_multiple_diversion_headers">>) of
        'true' -> list_to_binary([<<"ARRAY::">>, kz_binary:join(Diversions, <<"|:">>)]);
        'false' -> kz_binary:join(Diversions, <<",">>)
    end.

-spec encode_sip_multiparts_fold(kz_json:key(), kz_json:json_term(), iolist()) -> iolist().
encode_sip_multiparts_fold(Key, Value, Vars) ->
    lager:debug("setting multipart ~s on the channel", [Key]),
    [encode_fs_val(<<"sip_multipart_", Key/binary>>, Value) | Vars].
