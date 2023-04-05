%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc Dialplan API commands
%%% @author James Aimonetti
%%% @author Ben Wann
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fax).

-export([receive_fax/3]).

-spec receive_fax(atom(), kz_term:ne_binary(), kz_json:object()) -> kz_term:proplist().
receive_fax(_Node, UUID, JObj) ->
    [{<<"kz_multiset_encoded">>, t38_variables(UUID, JObj)}
    ,{<<"answer">>, <<>>}
    ,{<<"playback">>, <<"silence_stream://2000">>, [{<<"event-lock">>, <<"true">>}]}
    ,{<<"rxfax">>, fax_filename(UUID, JObj)}
    ].

fax_filename(UUID, JObj) ->
    Default = ecallmgr_util:fax_filename(UUID),
    kz_json:get_ne_binary_value(<<"Fax-Local-Filename">>, JObj, Default).

t38_variables(UUID, JObj) ->
    Vars = kz_json:filter(fun filter_t38/1, JObj),
    ecallmgr_util:multi_set_args(UUID, kz_json:to_proplist(Vars)).

filter_t38({K, _V}) ->
    lists:member(K, t38_headers()).

t38_headers() ->
    [<<"Enable-T38-Fax">>
    ,<<"Enable-T38-Fax-Request">>
    ,<<"Enable-T38-Passthrough">>
    ,<<"Enable-T38-Gateway">>
    ].
