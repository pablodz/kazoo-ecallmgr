%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2024, 2600Hz
%%% @doc Execute conference commands
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_conference_command).

-export([exec_cmd/3
        ,dial/4
        ,maybe_notify_participant/1
        ]).

-include("ecallmgr.hrl").

-define(SHOULD_NOTIFY_PARTICIPANTS
       ,kapps_config:is_true(?APP_NAME, <<"should_notify_participants">>, 'false')
       ).

-type api_response() :: 'ok' |
                        'error' |
                        ecallmgr_util:send_cmd_ret() |
                        [ecallmgr_util:send_cmd_ret(),...].

-spec exec_cmd(atom(), kz_term:ne_binary(), kz_json:object()) -> api_response().
exec_cmd(Node, ConferenceId, JObj) ->
    exec_cmd(Node, ConferenceId, JObj, kz_json:get_value(<<"Conference-ID">>, JObj)).

-spec exec_cmd(atom(), kz_term:ne_binary(), kz_json:object(), kz_term:ne_binary()) -> api_response().
exec_cmd(Node, ConferenceId, JObj, ConferenceId) ->
    App = kz_json:get_value(<<"Application-Name">>, JObj),
    case get_conf_command(App, ConferenceId, JObj) of
        {'error', Msg} -> throw({'msg', Msg});
        {_Cmd, 'noop'} -> 'ok';
        {_, _}=Cmd -> api(Node, ConferenceId, Cmd)
    end;
exec_cmd(_Node, _ConferenceId, JObj, _DestId) ->
    lager:debug("command ~s not meant for us (~s) but for ~s"
               ,[kz_json:get_value(<<"Application-Name">>, JObj)
                ,_ConferenceId
                ,_DestId
                ]).

-spec api(atom(), kz_term:ne_binary(), {kz_term:ne_binary(), iodata()}) -> api_response().
api(Node, ConferenceId, {AppName, AppData}) ->
    Command = kz_term:to_list(list_to_binary([ConferenceId, " ", AppName, " ", AppData])),
    lager:debug("api: ~s ~s", [Node, Command]),
    freeswitch:api(Node, 'conference', Command).

-spec get_conf_command(kz_term:ne_binary(), kz_term:ne_binary(), kz_json:object()) ->
          fs_app() | fs_apps() |
          {'return', 'error' | kz_term:ne_binary()} |
          {'error', kz_term:ne_binary()}.

%% The following conference commands can operate on the entire conference

get_conf_command(<<"lock">>, _ConferenceId, JObj) ->
    case kapi_conference:lock_v(JObj) of
        'false' ->
            {'error', <<"conference lock failed to execute as JObj did not validate.">>};
        'true' ->
            {<<"lock">>, <<>>}
    end;

get_conf_command(<<"unlock">>, _ConferenceId, JObj) ->
    case kapi_conference:unlock_v(JObj) of
        'false' ->
            {'error', <<"conference unlock failed to execute as JObj did not validate.">>};
        'true' ->
            {<<"unlock">>, <<>>}
    end;

get_conf_command(<<"record">>, _ConferenceId, JObj) ->
    case kapi_conference:record_v(JObj) of
        'false' ->
            {'error', <<"conference record failed to execute as JObj did not validate.">>};
        'true' ->
            MediaName = kz_json:get_value(<<"Media-Name">>, JObj),
            RecordingName = ecallmgr_util:recording_filename(MediaName),
            {<<"recording">>, [<<"start ">>, RecordingName]}
    end;

get_conf_command(<<"recordstop">>, _ConferenceId, JObj) ->
    case kapi_conference:recordstop_v(JObj) of
        'false' -> {'error', <<"conference recordstop failed validation">>};
        'true' ->
            MediaName = ecallmgr_util:recording_filename(kz_json:get_binary_value(<<"Media-Name">>, JObj)),
            {<<"recording">>, [<<"stop ">>, MediaName]}
    end;

get_conf_command(<<"tones">>, _ConferenceId, JObj) ->
    case kapi_conference:tones_v(JObj) of
        'false' -> {'error', <<"conference tones failed to validate">>};
        'true' ->
            Tones = kz_json:get_value(<<"Tones">>, JObj, []),
            FSTones = [begin
                           Vol = case kz_json:get_value(<<"Volume">>, Tone) of
                                     'undefined' -> [];
                                     %% need to map V (0-100) to FS values
                                     V -> list_to_binary(["v=", kz_term:to_list(V), ";"])
                                 end,
                           Repeat = case kz_json:get_value(<<"Repeat">>, Tone) of
                                        'undefined' -> [];
                                        R -> list_to_binary(["l=", kz_term:to_list(R), ";"])
                                    end,
                           Freqs = string:join([ kz_term:to_list(V) || V <- kz_json:get_value(<<"Frequencies">>, Tone) ], ","),
                           On = kz_term:to_list(kz_json:get_value(<<"Duration-ON">>, Tone)),
                           Off = kz_term:to_list(kz_json:get_value(<<"Duration-OFF">>, Tone)),
                           kz_term:to_list(list_to_binary([Vol, Repeat, "%(", On, ",", Off, ",", Freqs, ")"]))
                       end || Tone <- Tones],
            Arg = "tone_stream://" ++ string:join(FSTones, ";"),
            {<<"play">>, Arg}
    end;

%% The following conference commands can optionally specify a participant
get_conf_command(<<"play">>, ConferenceId, JObj) ->
    case kapi_conference:play_v(JObj) of
        'false' ->
            {'error', <<"conference play failed to execute as JObj did not validate.">>};
        'true' ->
            UUID = kz_json:get_ne_value(<<"Call-ID">>, JObj, ConferenceId),
            Media = list_to_binary(["'", ecallmgr_util:media_path(kz_json:get_value(<<"Media-Name">>, JObj), UUID, JObj), "'"]),
            Args = case kz_json:get_binary_value(<<"Participant-ID">>, JObj) of
                       'undefined' -> Media;
                       Participant -> list_to_binary([Media, " ", Participant])
                   end,
            {<<"play">>, Args}
    end;

get_conf_command(<<"play_macro">>, _ConferenceId, JObj) ->
    Participant = kz_json:get_binary_value(<<"Participant-ID">>, JObj, <<>>),
    Macro = kz_json:get_value(<<"Media-Macro">>, JObj, []),
    Paths = lists:map(fun ecallmgr_util:media_path/1, Macro),
    Media = list_to_binary(["'file_string://", kz_binary:join(Paths, <<"!">>), "'", " ", Participant]),
    {<<"play">>, Media};

get_conf_command(<<"stop_play">>, _ConferenceId, JObj) ->
    case kapi_conference:stop_play_v(JObj) of
        'false' ->
            {'error', <<"conference stop_play failed to execute as JObj did not validate.">>};
        'true' ->
            Affects = kz_json:get_binary_value(<<"Affects">>, JObj, <<"all">>),
            Args = case kz_json:get_binary_value(<<"Participant-ID">>, JObj) of
                       'undefined' -> Affects;
                       Participant -> list_to_binary([Affects, " ", Participant])
                   end,
            {<<"stop">>, Args}
    end;

get_conf_command(Say, _ConferenceId, JObj)
  when Say =:= <<"say">>;
       Say =:= <<"tts">> ->
    case kapi_conference:say_v(JObj) of
        'false' -> {'error', <<"conference say failed to validate">>};
        'true'->
            SayMe = kz_json:get_value(<<"Text">>, JObj),

            case kz_json:get_binary_value(<<"Participant-ID">>, JObj) of
                'undefined' -> {<<"say">>, ["'", SayMe, "'"]};
                Id -> {<<"saymember">>, [Id, " '", SayMe, "'"]}
            end
    end;

%% The following conference commands require a participant
get_conf_command(<<"kick">>, _ConferenceId, JObj) ->
    case kapi_conference:kick_v(JObj) of
        'false' ->
            {'error', <<"conference kick failed to execute as JObj did not validate.">>};
        'true' ->
            {<<"hup">>, kz_json:get_binary_value(<<"Participant-ID">>, JObj, <<"last">>)}
    end;

get_conf_command(<<"mute_participant">>, _ConferenceId, JObj) ->
    case kapi_conference:mute_participant_v(JObj) of
        'false' ->
            {'error', <<"conference mute_participant failed to execute as JObj did not validate.">>};
        'true' ->
            {<<"mute">>, kz_json:get_binary_value(<<"Participant-ID">>, JObj, <<"last">>)}
    end;

get_conf_command(<<"deaf_participant">>, _ConferenceId, JObj) ->
    case kapi_conference:deaf_participant_v(JObj) of
        'false' ->
            {'error', <<"conference deaf_participant failed to execute as JObj did not validate.">>};
        'true' ->
            {<<"deaf">>, kz_json:get_binary_value(<<"Participant-ID">>, JObj)}
    end;

get_conf_command(<<"participant_energy">>, _ConferenceId, JObj) ->
    case kapi_conference:participant_energy_v(JObj) of
        'false' ->
            {'error', <<"conference participant_energy failed to execute as JObj did not validate.">>};
        'true' ->
            Args = list_to_binary([kz_json:get_binary_value(<<"Participant-ID">>, JObj)
                                  ," ", kz_json:get_binary_value(<<"Energy-Level">>, JObj, <<"20">>)
                                  ]),
            {<<"energy">>, Args}
    end;

get_conf_command(<<"relate_participants">>, _ConferenceId, JObj) ->
    case kapi_conference:relate_participants_v(JObj) of
        'false' ->
            {'error', <<"conference relate_participants failed to execute as JObj did not validate.">>};
        'true' ->
            Args = list_to_binary([kz_json:get_binary_value(<<"Participant-ID">>, JObj)
                                  ," ", kz_json:get_binary_value(<<"Other-Participant">>, JObj)
                                  ," ", relationship(kz_json:get_binary_value(<<"Relationship">>, JObj))
                                  ]),
            {<<"relate">>, Args}
    end;

get_conf_command(<<"set">>, _ConferenceId, JObj) ->
    case kapi_conference:set_v(JObj) of
        'false' ->
            {'error', <<"conference set failed to execute as JObj did not validate.">>};
        'true' ->
            Args = list_to_binary([kz_json:get_binary_value(<<"Parameter">>, JObj)
                                  ," ", kz_json:get_binary_value(<<"Value">>, JObj)
                                  ]),
            {<<"set">>, Args}
    end;

get_conf_command(<<"undeaf_participant">>, _ConferenceId, JObj) ->
    case kapi_conference:undeaf_participant_v(JObj) of
        'false' ->
            {'error', <<"conference undeaf_participant failed to execute as JObj did not validate.">>};
        'true' ->
            {<<"undeaf">>, kz_json:get_binary_value(<<"Participant-ID">>, JObj)}
    end;

get_conf_command(<<"unmute_participant">>, _ConferenceId, JObj) ->
    case kapi_conference:unmute_participant_v(JObj) of
        'false' ->
            {'error', <<"conference unmute failed to execute as JObj did not validate.">>};
        'true' ->
            {<<"unmute">>, kz_json:get_binary_value(<<"Participant-ID">>, JObj)}
    end;

get_conf_command(<<"participant_volume_in">>, _ConferenceId, JObj) ->
    case kapi_conference:participant_volume_in_v(JObj) of
        'false' ->
            {'error', <<"conference participant_volume_in failed to execute as JObj did not validate.">>};
        'true' ->
            Args = list_to_binary([kz_json:get_binary_value(<<"Participant-ID">>, JObj)
                                  ," ", kz_json:get_binary_value(<<"Volume-In-Level">>, JObj, <<"0">>)
                                  ]),
            {<<"volume_in">>, Args}
    end;

get_conf_command(<<"participant_volume_out">>, _ConferenceId, JObj) ->
    case kapi_conference:participant_volume_out_v(JObj) of
        'false' ->
            {'error', <<"conference participant_volume_out failed to execute as JObj did not validate.">>};
        'true' ->
            Args = list_to_binary([kz_json:get_binary_value(<<"Participant-ID">>, JObj)
                                  ," ", kz_json:get_binary_value(<<"Volume-Out-Level">>, JObj, <<"0">>)
                                  ]),
            {<<"volume_out">>, Args}
    end;

get_conf_command(<<"vars">>, ConferenceId, JObj) ->
    case kapi_conference:vars_v(JObj) of
        'false' ->
            {'error', <<"conference custom_application_vars failed to execute as JObj did not validate.">>};
        'true' ->
            _ = update_conference_vars(ConferenceId, JObj),
            {<<"vars">>, 'noop'}
    end;

get_conf_command(<<"setvar">>, _ConferenceId, JObj) ->
    case kapi_conference:fs_conference_setvar_v(JObj) of
        'false' ->
            {'error', <<"conference setvar failed to execute as JObj did not validate.">>};
        'true' ->
            Parameter = kz_json:get_binary_value(<<"Parameter">>, JObj),
            Value = kz_json:get_binary_value(<<"Value">>, JObj),
            {<<"setvar">>, [Parameter, " ", Value]}
    end;

get_conf_command(Cmd, _ConferenceId, _JObj) ->
    lager:debug("unknown conference command ~s", [Cmd]),
    {'error', list_to_binary([<<"unknown conference command: ">>, Cmd])}.


custom_conference_vars(ConferenceId) ->
    case ecallmgr_fs_conferences:conference(ConferenceId) of
        {'ok', #conference{uuid=InstanceId
                          ,custom_conference_vars=Vars
                          }
        } ->
            {'ok', InstanceId, Vars};
        {'error', 'not_found'}=Error -> Error
    end.

update_conference_vars(ConferenceId, JObj) ->
    case custom_conference_vars(ConferenceId) of
        {'ok', InstanceId, Vars} ->
            update_conference_vars(ConferenceId, JObj, InstanceId, Vars);
        {'error', 'not_found'} ->
            lager:info("failed to find conference by name ~s", [ConferenceId]),
            {'error', <<"conference not found">>}
    end.

update_conference_vars(ConferenceId, JObj, InstanceId, Vars) ->
    NewVars = kz_json:get_json_value(<<"Custom-Conference-Vars">>, JObj, kz_json:new()),
    Update = kz_json:merge(Vars, NewVars),

    ecallmgr_fs_conferences:update(InstanceId
                                  ,{#conference.custom_conference_vars
                                   ,Update
                                   }),
    lager:info("updated conference ~s(~s) vars", [ConferenceId, InstanceId]),
    maybe_send_notify(ConferenceId, Update, ?SHOULD_NOTIFY_PARTICIPANTS).

maybe_send_notify(_ConferenceId, _Vars, 'false') -> 'ok';
maybe_send_notify(ConferenceId, Vars, 'true') ->
    NotifyJObj = vars_to_notify_jobj(Vars),
    _Sent = [maybe_notify_participant(Participant, NotifyJObj)
             || Participant <- ecallmgr_fs_conferences:participants(ConferenceId)
            ],
    'ok'.

vars_to_notify_jobj(Vars) ->
    case header_vars(Vars) of
        'undefined' -> 'undefined';
        HeaderValue ->
            kz_json:from_list([{<<"Custom-SIP-Headers">>
                               ,kz_json:from_list([{<<"X-Conference-Vars">>, HeaderValue}])
                               }
                              ,{<<"Event">>, <<"conference-vars">>}
                              ]
                             )
    end.

header_vars(Vars) ->
    case kz_binary:join(kz_json:foldr(fun encode_kv/3, [], Vars)
                       ,<<";">>
                       )
    of
        <<>> -> 'undefined';
        HeaderVars -> HeaderVars
    end.

-spec maybe_notify_participant(participant()) -> 'ok' | {'error', 'not_found'}.
maybe_notify_participant(Participant) ->
    maybe_notify_participant(Participant, ?SHOULD_NOTIFY_PARTICIPANTS).

maybe_notify_participant(#participant{}, 'false') -> 'ok';
maybe_notify_participant(#participant{}, 'undefined') -> 'ok';
maybe_notify_participant(#participant{conference_name=ConferenceId}=Participant, 'true') ->
    case custom_conference_vars(ConferenceId) of
        {'ok', _InstanceId, Vars} ->
            maybe_notify_participant(Participant, vars_to_notify_jobj(Vars));
        {'error', 'not_found'}=Error -> Error
    end;
maybe_notify_participant(#participant{uuid=CallId}, NotifyJObj) ->
    case ets:lookup(?CHANNELS_TBL, CallId) of
        [] -> {'error', <<"No channel found">>};
        [#channel{username=Username
                 ,realm=Realm
                 }
        ] ->
            ecallmgr_fs_notify:maybe_send_notify(Username, Realm, NotifyJObj),
            'ok'
    end.

-spec dial(atom(), kz_term:ne_binary(), kz_json:object(), kz_json:object() | kz_json:objects()) ->
          api_response().
dial(Node, ConferenceId, JObj, [_|_]=Endpoints) ->
    ChannelVars = ecallmgr_fs_xml:get_channel_vars(kz_json:set_value(<<"Outbound-Context">>, <<"context_2">>, JObj)),
    BridgeString = ecallmgr_fs_bridge:try_create_bridge_string(Endpoints, JObj),
    CallerIdNumber = kz_json:get_ne_binary_value(<<"Caller-ID-Number">>, JObj),
    CallerIdName = kz_json:get_ne_binary_value(<<"Caller-ID-Name">>, JObj),
    CallerId = caller_id(CallerIdNumber, CallerIdName),
    DialCmd = list_to_binary([ChannelVars, BridgeString, CallerId]),
    api(Node, ConferenceId, {<<"bgdial">>, DialCmd});
dial(Node, ConferenceId, JObj, Endpoint) ->
    dial(Node, ConferenceId, JObj, [Endpoint]).

-spec relationship(kz_term:ne_binary()) -> kz_term:ne_binary().
relationship(<<"mute">>) -> <<"nospeak">>;
relationship(<<"deaf">>) -> <<"nohear">>;
relationship(_) -> <<"clear">>.

-spec caller_id(kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> iodata().
caller_id('undefined', 'undefined') -> "";
caller_id('undefined', Name) -> [" ", $',$', " ", $', Name, $'];
caller_id(Number, 'undefined') -> [" ", Number];
caller_id(Number, Name) -> [" ", Number, " ", $', Name, $'].

encode_kv(K, V, Acc) -> [<<K/binary, "=", V/binary>> | Acc].
