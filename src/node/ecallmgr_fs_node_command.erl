%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
%%% @doc Execute node commands
%%% @author Luis Azedo
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_node_command).

-export([handle_req/2]).

-include("ecallmgr.hrl").

-spec handle_req(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_req(JObj, Props) ->
    kz_log:put_callid(JObj),
    Node = props:get_value('node', Props),
    Options = props:get_value('node_options', Props),
    'true' = kapi_switch:fs_command_v(JObj),
    Cmd = kz_json:get_ne_binary_value(<<"Command">>, JObj),
    Args = kz_json:get_json_value(<<"Args">>, JObj),
    exec_cmd(Cmd, Args, JObj, Node, Options).

-spec exec_cmd(kz_term:ne_binary(), kz_term:api_object(), kz_json:object(), atom(), kz_term:proplist()) -> 'ok'.
exec_cmd(<<"send_http">>, 'undefined', JObj, _Node, _Options) ->
    lager:debug("received http_send command with empty arguments"),
    reply_error(<<"no arguments">>, JObj);
exec_cmd(<<"send_http">>, Args, JObj, Node, Options) ->
    Version = props:get_value('client_version', Options),
    lager:debug("received http_send command for node ~s with version ~s", [Node, Version]),
    Url = kz_json:get_ne_binary_value(<<"Url">>, Args),
    File = kz_json:get_value(<<"File-Name">>, Args),
    Method = kz_term:to_lower_binary(kz_json:get_ne_binary_value(<<"Http-Method">>, Args, <<"put">>)),
    APIMethod = kz_term:to_atom(<<"kz_http_", Method/binary>>, 'true'),
    send_http(Node, File, Url, APIMethod, JObj);

exec_cmd(<<"call_command">>, 'undefined', JObj, _Node, _Options) ->
    lager:debug("received call_command command with empty arguments"),
    reply_error(<<"no arguments">>, JObj);
exec_cmd(<<"call_command">>, Cmd, JObj, Node, _Options) ->
    case call_command_allowed(kz_api:app_name(JObj), kapi_dialplan:application_name(Cmd)) of
        true -> call_command(Node, Cmd, JObj);
        false -> reply_error(<<"not allowed">>, JObj)
    end;

exec_cmd(Cmd, _Args, JObj, _Node, _Options) ->
    reply_error(<<Cmd/binary, " not_implemented">>, JObj).

-spec reply_error(kz_term:ne_binary(), kz_json:object()) -> 'ok'.
reply_error(Error, JObj) ->
    Values = [{<<"Result">>, <<"error">>}
             ,{<<"Error">>, Error}
             ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
             | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
             ],
    API = kz_json:set_values(Values, kz_api:remove_defaults(JObj)),
    send_reply(kz_api:server_id(JObj), API).

-spec reply_error(kz_term:ne_binary(), kz_json:object(), kz_json:object()) -> 'ok'.
reply_error(Error, EventData, JObj) ->
    Values = [{<<"Result">>, <<"error">>}
             ,{<<"Error">>, Error}
             ,{<<"Event-Data">>, EventData}
             ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
             | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
             ],
    API = kz_json:set_values(Values, kz_api:remove_defaults(JObj)),
    send_reply(kz_api:server_id(JObj), API).

-spec reply_success(kz_json:object(), kz_term:proplist()) -> 'ok'.
reply_success(JObj, Response) ->
    Values = [{<<"Result">>, <<"success">>}
             ,{<<"Response">>, kz_json:from_list(Response)}
             ,{<<"Msg-ID">>, kz_api:msg_id(JObj)}
             | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
             ],
    API = kz_json:set_values(Values, kz_api:remove_defaults(JObj)),
    send_reply(kz_api:server_id(JObj), API).

send_reply(undefined, _Payload) -> ok;
send_reply(Queue, Payload) ->
    kapi_switch:publish_fs_reply(Queue, Payload).

-spec send_http(atom(), binary(), binary(), atom(), kz_json:object()) -> 'ok'.
send_http(_Node, 'undefined', _Url, _Method, JObj) ->
    reply_error(<<"missing file">>, JObj);
send_http(_Node, _File, 'undefined', _Method, JObj) ->
    reply_error(<<"missing url">>, JObj);
send_http(Node, File, Url, Method, JObj) ->
    lager:debug("processing http_send command : ~s / ~s", [File, Url]),
    Args = <<Url/binary, " ", File/binary>>,
    Channel = kz_amqp_channel:consumer_channel(),
    case freeswitch:bgapi4(Node, Method, Args, fun send_http_cb/4, [JObj, File, Node, Channel]) of
        {'error', _Other} -> reply_error(<<"failure">>, JObj);
        {'ok', JobId} -> lager:debug("send_http command started ~p", [JobId])
    end.

-spec send_http_cb(atom(), kz_term:ne_binary(), kz_term:proplist(), list()) -> 'ok'.
send_http_cb('ok', _Reply, FSProps, [_JobId, JObj, _File, _Node, Channel]) ->
    lager:debug("processed http_send command (~s) ~s for file ~s with success : ~s"
               ,[_Node, _JobId, _File, kz_log:redactor(_Reply)]
               ),
    _ = kz_amqp_channel:consumer_channel(Channel),
    reply_success(JObj, FSProps);
send_http_cb('error', Reply, FSProps, [JobId, JObj, _File, _Node, Channel]) ->
    lager:debug("error processing http_send command ~s : ~p : ", [JobId, Reply]),
    _ = kz_amqp_channel:consumer_channel(Channel),
    Props = ecallmgr_util:unserialize_fs_props(FSProps),
    reply_error(Reply, kz_json:from_list(Props), JObj).

-spec call_command_allowed(kz_term:ne_binary(), kz_term:ne_binary()) -> boolean().
call_command_allowed(SenderApplication, CommandApplication) ->
    kz_app_config:is_true(?APP, [<<"node_call_command_allowed_applications">>, SenderApplication, CommandApplication]).

call_command(Node, Cmd, JObj) ->
    freeswitch:call_cmd_sync(true),
    case ecallmgr_call_command:exec_cmd(Node, kz_api:call_id(JObj), Cmd) of
        ok -> reply_success(JObj, [{<<"Call-Command-Result">>, <<"ok">>}]);
        {ok, Result} -> reply_success(JObj, [{<<"Call-Command-Result">>, Result}]);
        {error, Error} -> reply_error(Error, JObj);
        Other -> reply_error(term_to_binary(Other), JObj)
    end.
