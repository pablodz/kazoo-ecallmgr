%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2025, 2600Hz
%%% @doc Track the FreeSWITCH channel information, and provide accessors
%%% @author James Aimonetti
%%% @author Karl Anderson
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_channel).

-export([node/1, set_node/2
        ,former_node/1
        ,is_bridged/1
        ,exists/1
        ,import_moh/1
        ,set_account_id/2
        ,set_authorized/2
        ,fetch/1, fetch/2
        ,fetch_channel/1
        ,fetch_other_leg/1, fetch_other_leg/2
        ,renew/2
        ,channel_data/2
        ,get_other_leg/2
        ,new/3
        ,update/3
        ,new_or_update/3
        ]).
-export([to_json/1
        ,to_props/1
        ,channel_ccvs/1
        ,channel_cavs/1
        ,channel_cshs/1
        ,channel_cahs/1
        ]).
-export([to_api_json/1
        ,to_api_props/1
        ]).

-compile([{'no_auto_import', [node/1]}]).

-include("ecallmgr.hrl").
-include_lib("kazoo_sip/include/kzsip_uri.hrl").

-define(SYNC_TIMEOUT, 5 * ?MILLISECONDS_IN_SECOND).

%%%=============================================================================
%%% API
%%%=============================================================================
-type fetch_resp() :: kz_json:object() |
                      kz_term:proplist() |
                      channel().
-type channel_format() :: 'json' | 'proplist' | 'record' | 'api'.

-spec fetch(kz_term:ne_binary()) ->
          {'ok', fetch_resp()} |
          {'error', 'not_found'}.
fetch(UUID) ->
    fetch(UUID, 'json').

-spec fetch(kz_term:ne_binary(), channel_format()) ->
          {'ok', fetch_resp()} |
          {'error', 'not_found'}.
fetch(UUID, Format) ->
    case ets:lookup(?CHANNELS_TBL, UUID) of
        [Channel] -> {'ok', format(Format, Channel)};
        _Else -> {'error', 'not_found'}
    end.

-spec fetch_other_leg(kz_term:ne_binary()) ->
          {'ok', fetch_resp()} |
          {'error', 'not_found'}.
fetch_other_leg(UUID) ->
    fetch_other_leg(UUID, 'json').

-spec fetch_other_leg(kz_term:ne_binary(), channel_format()) ->
          {'ok', fetch_resp()} |
          {'error', 'not_found'}.
fetch_other_leg(UUID, Format) ->
    case ets:lookup(?CHANNELS_TBL, UUID) of
        [#channel{other_leg=OtherLeg}] -> fetch(OtherLeg, Format);
        _Else -> {'error', 'not_found'}
    end.

-spec format(channel_format(), channel()) -> fetch_resp().
format('json', Channel) -> to_json(Channel);
format('api', Channel) -> to_api_json(Channel);
format('proplist', Channel) -> to_props(Channel);
format('record', Channel) -> Channel.

-spec node(kz_term:ne_binary()) ->
          {'ok', atom()} |
          {'error', 'not_found'}.
node(UUID) ->
    MatchSpec = [{#channel{uuid = '$1', node = '$2', _ = '_'}
                 ,[{'=:=', '$1', {'const', UUID}}]
                 ,['$2']}
                ],
    case ets:select(?CHANNELS_TBL, MatchSpec) of
        [Node] -> {'ok', Node};
        _ -> {'error', 'not_found'}
    end.

-spec set_node(atom(), kz_term:ne_binary()) -> 'ok'.
set_node(Node, UUID) ->
    Updates =
        case node(UUID) of
            {'error', 'not_found'} -> [{#channel.node, Node}];
            {'ok', Node} -> [];
            {'ok', OldNode} ->
                [{#channel.node, Node}
                ,{#channel.former_node, OldNode}
                ]
        end,
    ecallmgr_fs_channels:updates(UUID, Updates).

-spec former_node(kz_term:ne_binary()) ->
          {'ok', atom()} |
          {'error', any()}.
former_node(UUID) ->
    MatchSpec = [{#channel{uuid = '$1', former_node = '$2', _ = '_'}
                 ,[{'=:=', '$1', {'const', UUID}}]
                 ,['$2']}
                ],
    case ets:select(?CHANNELS_TBL, MatchSpec) of
        ['undefined'] -> {'ok', 'undefined'};
        [Node] -> {'ok', Node};
        _ -> {'error', 'not_found'}
    end.

-spec is_bridged(kz_term:ne_binary()) -> boolean().
is_bridged(UUID) ->
    MatchSpec = [{#channel{uuid = '$1', other_leg = '$2', _ = '_'}
                 ,[{'=:=', '$1', {'const', UUID}}]
                 ,['$2']}
                ],
    case ets:select(?CHANNELS_TBL, MatchSpec) of
        ['undefined'] -> lager:debug("channel is not bridged"), 'false';
        [Bin] when is_binary(Bin) -> lager:debug("is bridged to: ~s", [Bin]), 'true';
        _E -> lager:debug("not bridged: ~p", [_E]), 'false'
    end.

-spec exists(kz_term:ne_binary()) -> boolean().
exists(UUID) -> ets:member(?CHANNELS_TBL, UUID).

-spec import_moh(kz_term:ne_binary()) -> boolean().
import_moh(UUID) ->
    try ets:lookup_element(?CHANNELS_TBL, UUID, #channel.import_moh)
    catch
        'error':'badarg':_ -> 'false'
    end.

-spec set_account_id(kz_term:ne_binary(), string() | kz_term:ne_binary()) -> 'ok'.
set_account_id(UUID, Value) when is_binary(Value) ->
    ecallmgr_fs_channels:update(UUID, #channel.account_id, Value);
set_account_id(UUID, Value) ->
    set_account_id(UUID, kz_term:to_binary(Value)).

-spec set_authorized(kz_term:ne_binary(), boolean() | kz_term:ne_binary()) -> 'ok'.
set_authorized(UUID, Value) ->
    ecallmgr_fs_channels:update(UUID, #channel.is_authorized, kz_term:is_true(Value)).

-spec renew(atom(), kz_term:ne_binary()) ->
          {'ok', channel()} |
          {'error', 'timeout' | 'badarg'}.
renew(Node, UUID) ->
    case channel_data(Node, UUID) of
        {'ok', JObj} -> {'ok', jobj_to_record(Node, UUID, JObj)};
        {'error', _}=E -> E
    end.

-spec channel_data(atom(), kz_term:ne_binary()) ->
          {'ok', kz_json:object()} |
          freeswitch:fs_api_error().
channel_data(Node, UUID) ->
    freeswitch:sync_channel(Node, UUID),
    receive
        {'channel_sync', JObj} -> {'ok', JObj}
    after ?SYNC_TIMEOUT ->
            {'error', 'timeout'}
    end.

-spec to_json(channel()) -> kz_json:object().
to_json(Channel) ->
    kz_json:from_list(to_props(Channel)).

-spec to_props(channel()) -> kz_term:proplist().
to_props(Channel) ->
    props:filter_undefined(
      [{<<"account_billing">>, Channel#channel.account_billing}
      ,{<<"account_id">>, Channel#channel.account_id}
      ,{<<"answered">>, Channel#channel.answered}
      ,{<<"authorizing_id">>, Channel#channel.authorizing_id}
      ,{<<"authorizing_type">>, Channel#channel.authorizing_type}
      ,{<<"bridge_id">>, Channel#channel.bridge_id}
      ,{<<"callflow_id">>, Channel#channel.callflow_id}
      ,{<<"channel_authorized">>, Channel#channel.is_authorized}
      ,{<<"context">>, Channel#channel.context}
      ,{<<"custom_application_vars">>, Channel#channel.cavs}
      ,{<<"custom_channel_vars">>, Channel#channel.ccvs}
      ,{<<"custom_sip_headers">>, Channel#channel.cshs}
      ,{<<"custom_auth_headers">>, Channel#channel.cahs}
      ,{<<"destination">>, Channel#channel.destination}
      ,{<<"request">>, Channel#channel.request}
      ,{<<"dialplan">>, Channel#channel.dialplan}
      ,{<<"direction">>, Channel#channel.direction}
      ,{<<"elapsed_s">>, kz_time:elapsed_s(Channel#channel.timestamp)}
      ,{<<"fetch_id">>, Channel#channel.fetch_id}
      ,{<<"from_tag">>, Channel#channel.from_tag}
      ,{<<"handling_locally">>, Channel#channel.handling_locally}
      ,{<<"interaction_id">>, Channel#channel.interaction_id}
      ,{<<"is_loopback">>, Channel#channel.is_loopback}
      ,{<<"is_onhold">>, Channel#channel.is_onhold}
      ,{<<"recording_status">>, Channel#channel.recording_status}
      ,{<<"loopback_leg_name">>, Channel#channel.loopback_leg_name}
      ,{<<"loopback_other_leg">>, Channel#channel.loopback_other_leg}
      ,{<<"node">>, Channel#channel.node}
      ,{<<"other_leg">>, Channel#channel.other_leg}
      ,{<<"owner_id">>, Channel#channel.owner_id}
      ,{<<"precedence">>, Channel#channel.precedence}
      ,{<<"presence_id">>, Channel#channel.presence_id}
      ,{<<"profile">>, Channel#channel.profile}
      ,{<<"realm">>, Channel#channel.realm}
      ,{<<"reseller_billing">>, Channel#channel.reseller_billing}
      ,{<<"reseller_id">>, Channel#channel.reseller_id}
      ,{<<"resource_id">>, Channel#channel.resource_id}
      ,{<<"switch_nodename">>, Channel#channel.node}
      ,{<<"switch_url">>, Channel#channel.switch_url}
      ,{<<"timestamp">>, Channel#channel.timestamp}
      ,{<<"to_tag">>, Channel#channel.to_tag}
      ,{<<"username">>, Channel#channel.username}
      ,{<<"uuid">>, Channel#channel.uuid}
      ]).

-spec to_api_json(kz_term:ne_binary() | channel()) -> kz_json:object().
to_api_json(Channel) ->
    kz_json:from_list(to_api_props(Channel)).

-spec to_api_props(kz_term:ne_binary() | channel()) -> kz_term:proplist().
to_api_props(#channel{}=Channel) ->
    props:filter_undefined(
      [{<<"Account-Billing">>, Channel#channel.account_billing}
      ,{<<"Account-ID">>, Channel#channel.account_id}
      ,{<<"Answered">>, Channel#channel.answered}
      ,{<<"Authorizing-ID">>, Channel#channel.authorizing_id}
      ,{<<"Authorizing-Type">>, Channel#channel.authorizing_type}
      ,{<<"Bridge-ID">>, Channel#channel.bridge_id}
      ,{<<"Call-Direction">>, Channel#channel.direction}
      ,{<<"Call-ID">>, Channel#channel.uuid}
      ,{<<"Callee-ID-Name">>, Channel#channel.callee_name}
      ,{<<"Callee-ID-Number">>, Channel#channel.callee_number}
      ,{<<"Caller-ID-Name">>, Channel#channel.caller_name}
      ,{<<"Caller-ID-Number">>, Channel#channel.caller_number}
      ,{<<"CallFlow-ID">>, Channel#channel.callflow_id}
      ,{<<"Channel-Authorized">>, Channel#channel.is_authorized}
      ,{<<"Context">>, Channel#channel.context}
      ,{<<"Custom-Application-Vars">>, Channel#channel.cavs}
      ,{<<"Custom-Channel-Vars">>, Channel#channel.ccvs}
      ,{<<"Custom-SIP-Headers">>, Channel#channel.cshs}
      ,{<<"Custom-AUTH-Headers">>, Channel#channel.cahs}
      ,{<<"Destination">>, Channel#channel.destination}
      ,{<<"Request">>, Channel#channel.request}
      ,{<<"Dialplan">>, Channel#channel.dialplan}
      ,{<<"Elapsed-Seconds">>, kz_time:elapsed_s(Channel#channel.timestamp)}
      ,{<<"Fetch-ID">>, Channel#channel.fetch_id}
      ,{<<"From">>, Channel#channel.from}
      ,{<<"From-Tag">>, Channel#channel.from_tag}
      ,{<<"Is-Loopback">>, Channel#channel.is_loopback}
      ,{<<"Is-On-Hold">>, Channel#channel.is_onhold}
      ,{<<"Recording-Status">>, Channel#channel.recording_status}
      ,{<<"Loopback-Leg-Name">>, Channel#channel.loopback_leg_name}
      ,{<<"Loopback-Other-Leg">>, Channel#channel.loopback_other_leg}
      ,{<<"Media-Node">>, kz_term:to_binary(Channel#channel.node)}
      ,{<<"Other-Leg-Call-ID">>, Channel#channel.other_leg}
      ,{<<"Owner-ID">>, Channel#channel.owner_id}
      ,{<<"Precedence">>, Channel#channel.precedence}
      ,{<<"Presence-ID">>, Channel#channel.presence_id}
      ,{<<"Profile">>, Channel#channel.profile}
      ,{<<"Realm">>, Channel#channel.realm}
      ,{<<"Reseller-Billing">>, Channel#channel.reseller_billing}
      ,{<<"Reseller-ID">>, Channel#channel.reseller_id}
      ,{<<"Resource-ID">>, Channel#channel.resource_id}
      ,{<<"Switch-URL">>, Channel#channel.switch_url}
      ,{<<"Timestamp">>, Channel#channel.timestamp}
      ,{<<"To">>, Channel#channel.to}
      ,{<<"To-Tag">>, Channel#channel.to_tag}
      ,{<<"Username">>, Channel#channel.username}
      ,{<<?CALL_INTERACTION_ID>>, Channel#channel.interaction_id}
      ]);
to_api_props(?NE_BINARY=CallId) ->
    {'ok', #channel{}=Channel} = fetch(CallId, 'record'),
    to_api_props(Channel).


-spec from_api_json(kz_json:object()) -> channel().
from_api_json(JObj) ->
    from_api_props(kz_json:to_proplist(<<"Channel-Record">>, JObj)).

-spec from_api_props(kz_term:proplist()) -> channel().
from_api_props(Props) ->
    #channel{account_billing = props:get_value(<<"Account-Billing">>, Props)
            ,account_id = props:get_value(<<"Account-ID">>, Props)
            ,answered = props:get_value(<<"Answered">>, Props)
            ,authorizing_id = props:get_value(<<"Authorizing-ID">>, Props)
            ,authorizing_type = props:get_value(<<"Authorizing-Type">>, Props)
            ,bridge_id = props:get_value(<<"Bridge-ID">>, Props)
            ,direction = props:get_value(<<"Call-Direction">>, Props)
            ,uuid = props:get_value(<<"Call-ID">>, Props)
            ,callee_name = props:get_value(<<"Callee-ID-Name">>, Props)
            ,callee_number = props:get_value(<<"Callee-ID-Number">>, Props)
            ,caller_name = props:get_value(<<"Caller-ID-Name">>, Props)
            ,caller_number = props:get_value(<<"Caller-ID-Number">>, Props)
            ,callflow_id = props:get_value(<<"CallFlow-ID">>, Props)
            ,is_authorized = props:get_value(<<"Channel-Authorized">>, Props)
            ,context = props:get_value(<<"Context">>, Props)
            ,cavs = props:get_value(<<"Custom-Application-Vars">>, Props)
            ,ccvs = props:get_value(<<"Custom-Channel-Vars">>, Props)
            ,cshs = props:get_value(<<"Custom-SIP-Headers">>, Props)
            ,cahs = props:get_value(<<"Custom-AUTH-Headers">>, Props)
            ,destination = props:get_value(<<"estination">>, Props)
            ,request = props:get_value(<<"Request">>, Props)
            ,dialplan = props:get_value(<<"Dialplan">>, Props)
            ,fetch_id = props:get_value(<<"Fetch-ID">>, Props)
            ,from = props:get_value(<<"From">>, Props)
            ,from_tag = props:get_value(<<"From-Tag">>, Props)
            ,is_loopback = props:get_value(<<"Is-Loopback">>, Props)
            ,is_onhold = props:get_value(<<"Is-On-Hold">>, Props)
            ,recording_status = props:get_value(<<"Recording-Status">>, Props)
            ,loopback_leg_name = props:get_value(<<"Loopback-Leg-Name">>, Props)
            ,loopback_other_leg = props:get_value(<<"Loopback-Other-Leg">>, Props)
            ,node = kz_term:to_atom(props:get_value(<<"Media-Node">>, Props), 'true')
            ,other_leg = props:get_value(<<"Other-Leg-Call-ID">>, Props)
            ,owner_id = props:get_value(<<"Owner-ID">>, Props)
            ,precedence = props:get_value(<<"Precedence">>, Props)
            ,presence_id = props:get_value(<<"Presence-ID">>, Props)
            ,profile = props:get_value(<<"Profile">>, Props)
            ,realm = props:get_value(<<"Realm">>, Props)
            ,reseller_billing = props:get_value(<<"Reseller-Billing">>, Props)
            ,reseller_id = props:get_value(<<"Reseller-ID">>, Props)
            ,resource_id = props:get_value(<<"Resource-ID">>, Props)
            ,switch_url = props:get_value(<<"Switch-URL">>, Props)
            ,timestamp = props:get_value(<<"Timestamp">>, Props)
            ,to = props:get_value(<<"To">>, Props)
            ,to_tag = props:get_value(<<"To-Tag">>, Props)
            ,username = props:get_value(<<"Username">>, Props)
            ,interaction_id = props:get_value(<<?CALL_INTERACTION_ID>>, Props)
            }.

-spec channel_ccvs(channel() | kz_json:object() | kz_term:proplist()) -> kz_term:proplist().
channel_ccvs(#channel{ccvs='undefined'}) -> [];
channel_ccvs(#channel{ccvs=CCVs}) -> kz_json:to_proplist(CCVs);
channel_ccvs([_|_]=Props) ->
    case props:get_value(<<"custom_channel_vars">>, Props, kz_json:new()) of
        List when is_list(List) -> List;
        JObj -> kz_json:to_proplist(JObj)
    end;
channel_ccvs(JObj) ->
    kz_json:to_proplist(kz_json:get_first_defined([<<"Custom-Channel-Vars">>
                                                  ,<<"custom_channel_vars">>
                                                  ], JObj, kz_json:new())).

-spec channel_cavs(channel() | kz_term:proplist() | kz_json:object()) -> kz_term:proplist().
channel_cavs(#channel{cavs='undefined'}) -> [];
channel_cavs(#channel{cavs=CAVs}) -> kz_json:to_proplist(CAVs);
channel_cavs([_|_]=Props) ->
    kz_json:to_proplist(props:get_value(<<"custom_application_vars">>, Props, kz_json:new()));
channel_cavs(JObj) ->
    kz_json:to_proplist(<<"Custom-Application-Vars">>, JObj).

-spec channel_cshs(channel() | kz_json:object() | kz_term:proplist()) -> kz_term:proplist().
channel_cshs(#channel{cshs='undefined'}) -> [];
channel_cshs(#channel{cshs=CSHs}) -> kz_json:to_proplist(CSHs);
channel_cshs([_|_]=Props) ->
    case props:get_value(<<"custom_sip_headers">>, Props, kz_json:new()) of
        List when is_list(List) -> List;
        JObj -> kz_json:to_proplist(JObj)
    end;
channel_cshs(JObj) ->
    kz_json:to_proplist(kz_json:get_first_defined([<<"Custom-SIP-Headers">>
                                                  ,<<"custom_sip_headers">>
                                                  ], JObj, kz_json:new())).

-spec channel_cahs(channel() | kz_json:object() | kz_term:proplist()) -> kz_term:proplist().
channel_cahs(#channel{cahs='undefined'}) -> [];
channel_cahs(#channel{cahs=CAHs}) -> kz_json:to_proplist(CAHs);
channel_cahs([_|_]=Props) ->
    case props:get_value(<<"custom_auth_headers">>, Props, kz_json:new()) of
        List when is_list(List) -> List;
        JObj -> kz_json:to_proplist(JObj)
    end;
channel_cahs(JObj) ->
    kz_json:to_proplist(kz_json:get_first_defined([<<"Custom-AUTH-Headers">>
                                                  ,<<"custom_auth_headers">>
                                                  ], JObj, kz_json:new())).

-spec fetch_channel(kz_term:ne_binary()) -> kz_term:proplist() | 'undefined'.
fetch_channel(UUID) ->
    fetch_channel(UUID, 'proplist').

-spec fetch_channel(kz_term:ne_binary(), channel_format()) -> fetch_resp() | 'undefined'.
fetch_channel(UUID, Format) ->
    case fetch(UUID, 'record') of
        {'error', 'not_found'} -> fetch_remote(UUID, Format);
        {'ok', Channel} -> format(Format, Channel)
    end.

-spec fetch_remote(kz_term:ne_binary(), channel_format()) -> fetch_resp() | 'undefined'.
fetch_remote(UUID, Format) ->
    case get_active_channel_status(UUID) of
        {'error', _} -> 'undefined';
        {'ok', JObj} -> format(Format, from_api_json(JObj))
    end.

-spec get_active_channel_status(kz_term:ne_binary()) -> kz_amqp_worker:request_return().
get_active_channel_status(UUID) ->
    Command = [{<<"Call-ID">>, UUID}
              ,{<<"Active-Only">>, 'true'}
              ,{<<"Channel-Record">>, 'true'}
              | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
              ],
    kz_amqp_worker:call(Command
                       ,fun kapi_call:publish_channel_status_req/1
                       ,fun kapi_call:channel_status_resp_v/1
                       ).

-spec get_other_leg(kz_term:api_binary(), kz_term:proplist()) -> kz_term:api_binary().
get_other_leg('undefined', _Props) -> 'undefined';
get_other_leg(UUID, Props) ->
    get_other_leg(UUID
                 ,Props
                 ,props:get_first_defined([<<"Other-Leg-Unique-ID">>
                                          ,<<"Other-Leg-Call-ID">>
                                          ,<<"variable_origination_uuid">>
                                          ]
                                         ,Props
                                         )
                 ).

-spec get_other_leg(kz_term:ne_binary(), kz_term:proplist(), kz_term:api_binary()) -> kz_term:api_binary().
get_other_leg(UUID, Props, 'undefined') ->
    maybe_other_bridge_leg(UUID
                          ,Props
                          ,props:get_value(<<"Bridge-A-Unique-ID">>, Props)
                          ,props:get_value(<<"Bridge-B-Unique-ID">>, Props)
                          );
get_other_leg(_UUID, _Props, OtherLeg) -> OtherLeg.

-spec maybe_other_bridge_leg(kz_term:ne_binary(), kz_term:proplist(), kz_term:ne_binary(), kz_term:ne_binary()) ->
          kz_term:api_binary().
maybe_other_bridge_leg(UUID, _Props, UUID, OtherLeg) -> OtherLeg;
maybe_other_bridge_leg(UUID, _Props, OtherLeg, UUID) -> OtherLeg;
maybe_other_bridge_leg(UUID, Props, _, _) ->
    case props:get_value(?GET_CCV(<<"Bridge-ID">>), Props) of
        UUID -> 'undefined';
        BridgeId -> BridgeId
    end.

-spec jobj_to_record(atom(), kz_term:ne_binary(), kz_json:object()) -> channel().
jobj_to_record(Node, UUID, JObj) ->
    lists:foldl(fun update_channel_property/2
               ,#channel{}
               ,jobj_to_updates(Node, UUID, JObj)
               ).

update_channel_property({Index, Value}, Channel) ->
    erlang:setelement(Index, Channel, Value).

jobj_to_updates(Node, UUID, JObj) ->
    CCVs = kz_json:get_json_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new()),
    CAVs = kz_json:get_json_value(<<"Custom-Application-Vars">>, JObj, kz_json:new()),
    CSHs = kz_json:get_json_value(<<"Custom-SIP-Headers">>, JObj, kz_json:new()),
    CAHs = kz_json:get_json_value(<<"Custom-AUTH-Headers">>, JObj),
    OtherLeg = kz_json:get_ne_binary_value(<<"Other-Leg-Call-ID">>, JObj),
    Profile = kz_json:get_ne_binary_value(<<"Caller-Profile">>, JObj, ?DEFAULT_FS_PROFILE),
    RecordingStatus = kz_json:get_json_value(<<"Recording-Status">>, JObj, kz_json:new()),

    props:filter_undefined([{#channel.uuid, UUID}
                           ,{#channel.destination, kz_json:get_ne_binary_value(<<"Caller-Destination-Number">>, JObj)}
                           ,{#channel.request, kz_json:get_ne_binary_value(<<"Request">>, JObj)}
                           ,{#channel.direction, kzd_freeswitch:original_call_direction(JObj)}

                           ,{#channel.account_id, kz_json:get_ne_binary_value(<<"Account-ID">>, CCVs)}
                           ,{#channel.account_billing, kz_json:get_ne_binary_value(<<"Account-Billing">>, CCVs)}
                           ,{#channel.authorizing_id, kz_json:get_ne_binary_value(<<"Authorizing-ID">>, CCVs)}
                           ,{#channel.authorizing_type, kz_json:get_ne_binary_value(<<"Authorizing-Type">>, CCVs)}
                           ,{#channel.is_authorized, kz_json:is_true(<<"Channel-Authorized">>, CCVs)}
                           ,{#channel.owner_id, kz_json:get_ne_binary_value(<<"Owner-ID">>, CCVs)}
                           ,{#channel.resource_id, kz_json:get_ne_binary_value(<<"Resource-ID">>, CCVs)}
                           ,{#channel.fetch_id, kz_json:get_ne_binary_value(<<"Fetch-ID">>, CCVs)}
                           ,{#channel.bridge_id, kz_json:get_ne_binary_value(<<"Bridge-ID">>, CCVs, UUID)}
                           ,{#channel.reseller_id, kz_json:get_ne_binary_value(<<"Reseller-ID">>, CCVs)}
                           ,{#channel.reseller_billing, kz_json:get_ne_binary_value(<<"Reseller-Billing">>, CCVs)}
                           ,{#channel.precedence, kz_term:to_integer(kz_json:get_integer_value(<<"Precedence">>, CCVs, 5))}

                           ,{#channel.presence_id, kz_json:get_ne_binary_value(<<"Presence-ID">>, JObj)}
                           ,{#channel.realm, kz_json:get_ne_binary_value(<<"Realm">>, CCVs)}
                           ,{#channel.username, kz_json:get_ne_binary_value(<<"Username">>, CCVs)}

                           ,{#channel.answered, kz_call_event:channel_answer_state(JObj) =:= <<"answered">>}
                           ,{#channel.node, Node}
                           ,{#channel.timestamp, kz_time:current_tstamp()}

                           ,{#channel.profile, Profile}
                           ,{#channel.context, kzd_freeswitch:context(JObj, ?DEFAULT_FREESWITCH_CONTEXT)}
                           ,{#channel.dialplan, kz_json:get_ne_binary_value(<<"Caller-Dialplan">>, JObj, ?DEFAULT_FS_DIALPLAN)}

                           ,{#channel.other_leg, OtherLeg}
                           ,{#channel.handling_locally, handling_locally(kz_json:get_ne_binary_value(<<"Ecallmgr-Node">>, CCVs), OtherLeg)}

                           ,{#channel.to_tag, kzd_freeswitch:to_tag(JObj)}
                           ,{#channel.from_tag, kzd_freeswitch:from_tag(JObj)}

                           ,{#channel.interaction_id, kz_json:get_ne_binary_value(<<?CALL_INTERACTION_ID>>, CCVs)}

                           ,{#channel.is_loopback, kzd_freeswitch:is_loopback(JObj)}
                           ,{#channel.loopback_leg_name, kzd_freeswitch:loopback_leg_name(JObj)}
                           ,{#channel.loopback_other_leg, kzd_freeswitch:loopback_other_leg(JObj)}

                           ,{#channel.callflow_id, kz_json:get_ne_binary_value(<<"CallFlow-ID">>, CCVs)}
                           ,{#channel.cavs, CAVs}
                           ,{#channel.ccvs, CCVs}
                           ,{#channel.cshs, CSHs}
                           ,{#channel.cahs, CAHs}
                           ,{#channel.recording_status, RecordingStatus}
                           ,{#channel.from, kzd_freeswitch:from(JObj)}
                           ,{#channel.to, kzd_freeswitch:to(JObj)}
                           ,{#channel.switch_url, switch_url(Node, JObj, Profile)}
                           ]).

switch_url(Node, JObj, Profile) ->
    case kzd_freeswitch:switch_url(JObj) of
        'undefined' -> ecallmgr_fs_nodes:sip_url(Node, Profile);
        URL -> URL
    end.

-spec handling_locally(kz_term:api_binary(), kz_term:api_binary()) -> boolean().
handling_locally('undefined', 'undefined') -> 'false';
handling_locally(Node, _X) ->
    Node =:= kz_term:to_binary(node()).

%% @doc for CHANNEL_CREATE, insert new record
-spec new(atom(), kz_term:ne_binary(), kz_json:object()) -> 'ok'.
new(Node, UUID, JObj) ->
    InteractionId = kzd_freeswitch:ccv(JObj, <<"Call-Interaction-ID">>),
    case kzd_freeswitch:other_leg_call_id(JObj) of
        'undefined' ->
            lager:info("adding new channel ~s with interaction id ~s", [UUID, InteractionId]);
        OtherLegId ->
            lager:info("adding new channel ~s with interaction id ~s bridged to ~s"
                      ,[UUID, InteractionId, OtherLegId]
                      )
    end,
    ecallmgr_fs_channels:new(jobj_to_record(Node, UUID, JObj)).

%% @doc for CHANNEL_SYNC, insert or update the channel record
-spec new_or_update(atom(), kz_term:ne_binary(), kz_json:object()) -> 'ok'.
new_or_update(Node, UUID, JObj) ->
    ecallmgr_fs_channels:new_or_update(jobj_to_record(Node, UUID, JObj)).

%% @doc for all other events, only update the channel record if the record exists
-spec update(atom(), kz_term:ne_binary(), kz_json:object()) -> 'ok'.
update(Node, UUID, JObj) ->
    ecallmgr_fs_channels:updates(UUID, jobj_to_updates(Node, UUID, JObj)).
