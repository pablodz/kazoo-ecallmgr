%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2025, 2600Hz
%%% @doc Receives RECORD_START, RECORD_STOP, RECORD_MASK, RECORD_UNMASK,
%%% RECORD_PAUSE and RECORD_RESUME events
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_recordings).

-export([init/0]).
-export([handle_record_stop/1
        ,handle_recording_event/1
        ,update_state/2
        ]).

-include("ecallmgr.hrl").

-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"event_stream.event.call_event.RECORD_STOP">>, ?MODULE, 'handle_record_stop'),
    _ = kazoo_bindings:bind([
                             <<"event_stream.event.call_event.RECORD_START">>,
                             <<"event_stream.event.call_event.RECORD_STOP">>,
                             <<"event_stream.event.call_event.RECORD_MASK">>,
                             <<"event_stream.event.call_event.RECORD_UNMASK">>,
                             <<"event_stream.event.call_event.RECORD_PAUSE">>,
                             <<"event_stream.event.call_event.RECORD_RESUME">>
                            ], ?MODULE, 'handle_recording_event'),
    'ok'.

-spec handle_record_stop(map()) -> any().
handle_record_stop(#{node := Node, call_id := UUID, payload := Event}) ->
    kz_log:put_callid(UUID),
    IsLocal = handling_locally(Event),
    MediaRecorder = kz_recording:recorder(Event),
    maybe_store_recording(IsLocal, MediaRecorder, Event, UUID, Node).

-spec handle_recording_event(map()) -> any().
handle_recording_event(#{node := _Node, call_id := UUID, payload := Event}) ->
    kz_log:put_callid(UUID),
    case kz_recording:name(Event) of
        Name when is_binary(Name) ->
            RecordingID = filename:rootname(Name),
            ecallmgr_fs_channels:update_recording_status(UUID, RecordingID, kz_call_event:event_name(Event));
        _ ->
            lager:debug("not a call recording event, ignoring"),
            'ok'
    end.

-spec update_state(any(), kz_term:ne_binary()) -> any().
update_state(_, <<"RECORD_START">>) -> 'recording';
update_state(_, <<"RECORD_STOP">>) -> 'stopped';
update_state('recording', <<"RECORD_MASK">>) -> 'masked';
update_state('paused', <<"RECORD_MASK">>) -> 'paused_and_masked';
update_state('masked', <<"RECORD_UNMASK">>) -> 'recording';
update_state('paused_and_masked', <<"RECORD_UNMASK">>) -> 'paused';
update_state('recording', <<"RECORD_PAUSE">>) -> 'paused';
update_state('masked', <<"RECORD_PAUSE">>) -> 'paused_and_masked';
update_state('paused', <<"RECORD_RESUME">>) -> 'recording';
update_state('paused_and_masked', <<"RECORD_RESUME">>) -> 'masked';
update_state(State, _) -> State.

-spec maybe_store_recording(boolean(), kz_term:api_binary(), kz_json:object(), kz_term:ne_binary(), atom()) ->
          'ok' |
          'error' |
          ecallmgr_util:send_cmd_ret() |
          [ecallmgr_util:send_cmd_ret(),...].
maybe_store_recording('false', _, _JObj, _CallId, _Node) -> 'ok';
maybe_store_recording('true', ?KZ_RECORDER, _Props, _CallId, _Node) -> 'ok';
maybe_store_recording('true', _, JObj, CallId, Node) ->
    case kz_recording:transfer_destination(JObj) of
        'undefined' -> 'ok';
        <<>> -> 'ok';
        <<Destination/binary>> ->
            kz_log:put_callid(CallId),
            lager:debug("no one is handling call recording, storing recording to ~s", [Destination]),

            MediaName = kz_call_event:custom_channel_var(JObj, <<"Media-Name">>),
            %% TODO: if you change this logic be sure it matches kz_media_util as well!
            Url = kz_binary:join([kz_binary:strip_right(Destination, $/)
                                 ,MediaName
                                 ]
                                ,<<"/">>
                                ),

            Cmd = kz_json:from_list(
                    [{<<"Call-ID">>, CallId}
                    ,{<<"Msg-ID">>, CallId}
                    ,{<<"Media-Name">>, MediaName}
                    ,{<<"Media-Transfer-Destination">>, Url}
                    ,{<<"Insert-At">>, <<"now">>}
                    ,{<<"Media-Transfer-Method">>, media_transfer_method(JObj)}
                    ,{<<"Application-Name">>, <<"store">>}
                    ,{<<"Event-Category">>, <<"call">>}
                    ,{<<"Event-Name">>, <<"command">>}
                    | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                    ]),
            ecallmgr_call_command:exec_cmd(Node, CallId, Cmd)
    end.

-spec media_transfer_method(kz_json:object()) -> kz_term:ne_binary().
media_transfer_method(JObj) ->
    kz_recording:transfer_method(JObj, <<"put">>).

-spec handling_locally(kz_json:object()) -> boolean().
handling_locally(JObj) ->
    handling_locally(JObj, kz_call_event:other_leg_call_id(JObj)).

-spec handling_locally(kz_json:object(), kz_term:api_binary()) -> boolean().
handling_locally(JObj, 'undefined') ->
    kz_call_event:custom_channel_var(JObj, <<"Ecallmgr-Node">>) =:= kz_term:to_binary(node());
handling_locally(JObj, OtherLeg) ->
    Node = kz_term:to_binary(node()),
    case kz_call_event:custom_channel_var(JObj, <<"Ecallmgr-Node">>) of
        Node -> 'true';
        _ -> other_leg_handling_locally(OtherLeg)
    end.

-spec other_leg_handling_locally(kz_term:ne_binary()) -> boolean().
other_leg_handling_locally(OtherLeg) ->
    case ecallmgr_fs_channel:fetch(OtherLeg, 'record') of
        {'ok', #channel{handling_locally=HandleLocally}} -> HandleLocally;
        _ -> 'false'
    end.
