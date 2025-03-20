%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2025, 2600Hz
%%% @doc Execute conference commands
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_conference_stream).

%% API
-export([init/0
        ,handle_event/1
        ]).

-include("ecallmgr.hrl").

-define(MEMBER_UPDATE_EVENTS, [<<"stop-talking">>
                              ,<<"start-talking">>
                              ,<<"mute-member">>
                              ,<<"unmute-member">>
                              ,<<"deaf-member">>
                              ,<<"undeaf-member">>
                              ]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"event_stream.process.conference.event">>, ?MODULE, 'handle_event'),
    'ok'.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(map()) -> 'ok'.
handle_event(#{node := Node, payload := JObj}) ->
    Event = kz_conference_event:event(JObj),
    lager:debug("handle conference event ~s ~s", [Node, Event]),
    process_event(Event, JObj, Node).

-spec process_event(kz_term:ne_binary(), kz_json:object(), atom()) -> any().
process_event(<<"conference-create">>, JObj, Node) ->
    _ = set_conference_interaction_id(Node, JObj),
    _ = ecallmgr_fs_conferences:create(JObj, Node),
    ConferenceId = kz_conference_event:conference_id(JObj),
    UUID = kz_conference_event:instance_id(JObj),
    ecallmgr_conference_control_sup:start_conference_control(Node, ConferenceId, UUID);
process_event(<<"conference-destroy">>, JObj, Node) ->
    ConferenceId = kz_conference_event:conference_id(JObj),
    InstanceId = kz_conference_event:instance_id(JObj),
    _ = ecallmgr_fs_conferences:destroy(InstanceId),
    _ = ecallmgr_conference_control_sup:stop_conference_control(Node, ConferenceId, InstanceId);

process_event(<<"start-recording">>, JObj, _Node) ->
    lager:info("conference recording started"),
    AccountId = kz_json:get_binary_value(<<"Account-ID">>, JObj),
    ConferenceName = kz_json:get_binary_value(<<"Conference-ID">>, JObj),
    Data = recording_data(AccountId, ConferenceName),
    CommandReq =
        [{<<"Conference-ID">>, ConferenceName}
        ,{<<"Parameter">>, <<"Recording-Data">>}
        ,{<<"Value">>, Data}
        ,{<<"Application-Name">>, <<"setvar">>}
        | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
        ],
    kapi_conference:publish_fs_conference_setvar(ConferenceName, CommandReq);
process_event(<<"stop-recording">>, _JObj, _Node) ->
    lager:info("conference recording stopped");

process_event(<<"add-member">>, JObj, Node) ->
    _ = set_participant_interaction_id(Node, JObj),
    ecallmgr_fs_conferences:participant_create(JObj, Node);
process_event(<<"del-member">>, JObj, _Node) ->
    ecallmgr_fs_conferences:participant_destroy(kz_conference_event:call_id(JObj));

process_event(<<"lock">>, JObj, _) ->
    UUID = kz_conference_event:instance_id(JObj),
    ecallmgr_fs_conferences:update(UUID, {#conference.locked, 'true'});
process_event(<<"unlock">>, JObj, _) ->
    UUID = kz_conference_event:instance_id(JObj),
    ecallmgr_fs_conferences:update(UUID, {#conference.locked, 'false'});
process_event(Event, JObj, _Node) ->
    case lists:member(Event, ?MEMBER_UPDATE_EVENTS) of
        'true' -> update_participant(JObj);
        'false' -> 'ok'
    end.

update_participant(JObj) ->
    ConferenceVars = kz_conference_event:conference_channel_vars(JObj),
    CustomVars = kz_conference_event:custom_channel_vars(JObj),
    AppVars = kz_conference_event:custom_application_vars(JObj),
    UUID = kz_conference_event:call_id(JObj),
    Update = [{#participant.conference_channel_vars, ConferenceVars}
             ,{#participant.custom_channel_vars, CustomVars}
             ,{#participant.custom_application_vars, AppVars}
             ],
    ecallmgr_fs_conferences:participant_update(UUID, Update).

should_process_interaction() ->
    kapps_config:get_boolean(?INTERACTION_CAT, <<"process_conference">>, 'true').

-spec set_conference_interaction_id(atom(), kz_json:object()) -> 'ok' | pid().
set_conference_interaction_id(Node, JObj) ->
    set_conference_interaction_id(Node, JObj, should_process_interaction()).

-spec set_conference_interaction_id(atom(), kz_json:object(), boolean() | kz_term:api_ne_binary()) -> 'ok' | pid().
set_conference_interaction_id(_Node, _JObj, 'false') -> 'ok';
set_conference_interaction_id(Node, JObj, 'true') ->
    case kzd_interaction:id(JObj) of
        'undefined' -> 'ok';
        ID -> set_conference_interaction_id(Node, JObj, ID)
    end;
set_conference_interaction_id(_Node, _JObj, 'undefined') -> 'ok';
set_conference_interaction_id(Node, JObj, InteractionId) ->
    ConferenceId = kz_conference_event:conference_id(JObj),
    Args = list_to_binary([ConferenceId, " set_var Conference-Interaction-ID ", InteractionId]),
    kz_process:spawn(fun freeswitch:api/3, [Node, 'conference', Args]).

-spec set_participant_interaction_id(atom(), kz_json:object()) -> 'ok' | pid().
set_participant_interaction_id(Node, JObj) ->
    set_participant_interaction_id(Node, JObj, should_process_interaction()).

-spec set_participant_interaction_id(atom(), kz_json:object(), boolean() | kz_term:api_ne_binary()) ->
          'ok' | pid().
set_participant_interaction_id(_Node, _JObj, 'false') -> 'ok';
set_participant_interaction_id(Node, JObj, 'true') ->
    set_participant_interaction_id(Node, JObj, conference_interaction_id(JObj));
set_participant_interaction_id(_Node, _JObj, 'undefined') ->
    lager:debug("conference interaction-id is undefined, not setting on participant");
set_participant_interaction_id(Node, JObj, ID) ->
    CallId = kz_conference_event:call_id(JObj),
    Args = list_to_binary([CallId, " ", ?CALL_INTERACTION_ID, " ", ID]),
    kz_process:spawn(fun freeswitch:api/3, [Node, 'kz_uuid_setvar', Args]).

-spec conference_interaction_id(kz_json:object()) -> kz_term:api_ne_binary().
conference_interaction_id(JObj) ->
    case kz_conference_event:conference_vars(JObj) of
        'undefined' -> 'undefined';
        Vars -> kz_json:get_ne_binary_value(<<"Interaction-ID">>, Vars)
    end.

-spec recording_data(kz_term:ne_binary(),  kz_json:object()) -> kz_term:ne_binary().
recording_data(AccountId, ConfId) ->
    {Year, Month, _} = erlang:date(),
    MediaDocId = ?MATCH_MODB_PREFIX(kz_term:to_binary(Year), kz_date:pad_month(Month), kz_binary:rand_hex(16)),
    AccountDb = kzs_util:format_account_db(AccountId),
    {RecordingUrl, ConfName} =
        case kz_datamgr:open_cache_doc(AccountDb, ConfId) of
            {'ok', Doc} ->
                {kz_json:get_ne_binary_value(<<"recording_url">>, Doc)
                ,kz_json:get_ne_binary_value(<<"name">>, Doc)
                };
            {'error', _Error} ->
                {'undefined', 'undefined'}
        end,
    Recorder = kapps_call_recording:media_recorder(kz_json:from_list([{<<"url">>, RecordingUrl}]), AccountId),
    Prop = [{<<"Recorder">>, Recorder}
           ,{<<"url">>, RecordingUrl}
           ,{<<"ID">>, MediaDocId}
           ,{<<"Conference-Name">>, ConfName}
           ],
    base64:encode(term_to_binary(kz_json:from_list(Prop))).
