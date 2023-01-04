%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc Directory lookups from FS
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fetch_limit).

-export([fetch_limit/1]).
-export([init/0]).

-import(ecallmgr_fs_xml
       ,[section_el/2
        ,xml_attrib/2
        ]).

-include("ecallmgr.hrl").

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"fetch.directory.limit.#">>, ?MODULE, 'fetch_limit'),
    'ok'.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec fetch_limit(map()) -> fs_handlecall_ret().
fetch_limit(#{node := Node, fetch_id := FetchId, payload := JObj}=Context) ->
    kz_log:put_callid(JObj),
    lager:debug("received limit request ~s for ~s from ~s"
               ,[FetchId, kzd_fetch:fetch_key_value(JObj), Node]
               ),
    fetch_limit(Context, endpoint(JObj)).

-spec endpoint(kz_json:object()) -> tuple().
endpoint(JObj) ->
    EndpointId = kzd_fetch:fetch_key_value(JObj),
    Args = binary:split(EndpointId, <<"@">>),
    list_to_tuple(Args).

-spec fetch_limit(map(), tuple()) -> fs_handlecall_ret().
fetch_limit(Context, {EndpointId, AccountId}) ->
    check_limit(Context#{endpoint_id => EndpointId, account_id => AccountId});
fetch_limit(#{fetch_id := FetchId, node := Node, payload := JObj}=Context, _) ->
    lager:debug("limit format not expected from ~s => ~p on request ~s"
               ,[Node, kzd_fetch:fetch_key_value(JObj), FetchId]
               ),
    limit_not_found(Context).

-spec check_limit(map()) -> fs_handlecall_ret().
check_limit(#{payload := JObj} = Context) ->
    case kz_json:get_integer_value([<<"Fetch-Params">>, <<"Channel-Limit">>], JObj) of
        'undefined' -> check_endpoint_limits(Context);
        Value -> check_endpoint_limit(Context, Value)
    end.

check_endpoint_limits(#{payload := JObj} = Context) ->
    case kz_json:get_json_value([<<"Fetch-Params">>, <<"Endpoint-Call-Limits">>], JObj) of
        'undefined' -> limit_not_found(Context);
        Value -> check_endpoint_limits(Context, kz_maps:keys_to_atoms(kz_json:to_map(Value)))
    end.

check_endpoint_limits(Context, Limits) ->
    Q = create_query(Context),
    R = kz_channels:count(Q),
    F = maps:filter(fun(K, V) -> maps:get(K, R, 0) >= V end, Limits),
    log_limits(F),
    reply_limit(Context, maps:size(F) =:= 0).

log_limits(Limits) ->
    %% maps:foreach requires OTP24
    %% maps:foreach(fun log_limit/2, Limits).
    Iterator = maps:iterator(Limits),
    iterate_log_limits(maps:next(Iterator)).

iterate_log_limits('none') -> 'ok';
iterate_log_limits({K, V, Iterator}) ->
    log_limit(K, V),
    iterate_log_limits(maps:next(Iterator)).

log_limit(K, V) ->
    lager:notice("~s limit of ~B reached",[K, V]).

check_endpoint_limit(#{endpoint_id := EndpointId, account_id := AccountId} = Context, Value) ->
    Count = kz_endpoint:channel_count(EndpointId, AccountId),
    reply_limit(Context, Count < Value).

-spec reply_limit(map(), boolean()) -> fs_handlecall_ret().
reply_limit(#{fetch_id := FetchId
             ,node := Node
             ,payload := JObj
             ,endpoint_id := EndpointId
             ,account_id := AccountId
             } = Context
           ,Success
           ) ->
    {'ok', Xml} = limit_resp_xml(Success, JObj),
    lager:debug("sending limit ~s (~s/~s) XML to ~w for request ~s"
               ,[Success, EndpointId, AccountId, Node, FetchId]
               ),
    freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Xml)}).


-spec limit_resp_xml(boolean(), kz_json:object()) -> {'ok', iolist()}.
limit_resp_xml(Limit, JObj) ->
    Id = kzd_fetch:fetch_key_value(JObj),
    LocationEl = limit_el(Id, kz_term:to_binary(Limit)),
    SectionEl = section_el(<<"directory">>,  LocationEl),
    {'ok', xmerl:export([SectionEl], 'fs_xml')}.

-spec limit_el(kz_types:xml_attrib_value(), kz_types:xml_attrib_value()) -> kz_types:xml_el().
limit_el(Id, Value) ->
    #xmlElement{name='limit'
               ,attributes=[xml_attrib('id', Id)
                           ,xml_attrib('value', Value)
                           ]
               }.

-spec limit_not_found(map()) -> fs_handlecall_ret().
limit_not_found(#{fetch_id := FetchId, node := Node, payload := JObj} = Context) ->
    {'ok', Xml} = ecallmgr_fs_xml:not_found(<<"limit">>),
    lager:debug("sending directory limit (~s) not found XML to ~w for request ~s"
               ,[kzd_fetch:fetch_key_value(JObj), Node, FetchId]
               ),
    freeswitch:fetch_reply(Context#{reply => iolist_to_binary(Xml)}).

create_query(Context) ->
    Routines = [fun add_account/1
               ,fun add_type/1
               ,fun add_user/1
               ],
    maps:get('query', kz_maps:exec(Routines, maps:put('query', #{}, Context))).

add_account(#{account_id := AccountId, query := Query} = Context) ->
    maps:put('query', maps:put('account', AccountId, Query), Context).

add_type(#{payload := JObj, endpoint_id := EndpointId, query := Query} = Context) ->
    Type = kz_json:get_atom_value([<<"Fetch-Params">>, <<"Endpoint-Type">>], JObj),
    maps:put('query', maps:put(Type, EndpointId, Query), Context).

add_user(#{query := #{'user' := _}} = Context) -> Context;
add_user(#{payload := JObj, query := Query} = Context) ->
    case kz_json:get_ne_binary_value([<<"Fetch-Params">>, <<"Endpoint-Owner-ID">>], JObj) of
        'undefined' -> Context;
        OwnerId -> maps:put('query', maps:put('user', OwnerId, Query), Context)
    end.
