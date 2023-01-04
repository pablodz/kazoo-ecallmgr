%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2023, 2600Hz
%%% @doc Associates endpoint ID(s) with destinations for fast routing
%%% (bypassing authz_req and route_req)
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_quickroute_listener).
-behaviour(gen_listener).

-export([start_link/0
        ,cache_name/0
        ,get_quickroutes/0, get_quickroute/1
        ,handle_quickroute/2
        ,add_quickroute/3, add_quickroute/4

        ,handle_quickroutes_query/2
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).
-type state() :: #state{}.

-define(BINDINGS, [{'route', [{'restrict_to', ['quickroute', 'query_quickroutes_req']}, 'federate']}]).
-define(RESPONDERS, [{{?MODULE, 'handle_quickroute'}
                     ,[{<<"dialplan">>, <<"quickroute">>}]
                     }
                    ,{{?MODULE, 'handle_quickroutes_query'}
                     ,[{<<"dialplan">>, <<"query_quickroutes_req">>}]
                     }
                    ]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-define(DEFAULT_EXPIRY, kapps_config:get_integer(?APP_NAME, <<"quickroute_expiry_s">>, 300)).

-define(CACHE_KEY(Number), {?MODULE, Number}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_listener:start_link(?SERVER
                           ,[{'bindings', ?BINDINGS}
                            ,{'responders', ?RESPONDERS}
                            ,{'queue_name', ?QUEUE_NAME}       % optional to include
                            ,{'queue_options', ?QUEUE_OPTIONS} % optional to include
                            ,{'consume_options', ?CONSUME_OPTIONS} % optional to include
                            ]
                           ,[]
                           ).

-spec cache_name() -> 'quickroute_cache'.
cache_name() -> 'quickroute_cache'.

%% QuickRoute resp:
%% Method : bridge
%% Routes : [EndpointJObj]
%% EndpointJObj :
%%   Endpoint-URI : EndpointID@AccountID
%%   Invite-Format: endpoint

-spec get_quickroute(kz_term:ne_binaries()) -> kz_term:api_object().
get_quickroute([]) -> 'undefined';
get_quickroute([Number | Numbers]) ->
    case kz_cache:peek_local(cache_name(), cache_key(Number)) of
        {'error', 'not_found'} -> get_quickroute(Numbers);
        {'ok', QuickRoute} ->
            lager:info("found quickroute for ~s", [Number]),
            QuickRoute
    end.

-spec get_quickroutes() -> kz_json:objects().
get_quickroutes() ->
    kz_cache:map_local(cache_name(), fun export_quickroute/2).

export_quickroute(?CACHE_KEY(Number), QuickRoute) ->
    kz_json:set_value(<<"Number">>, Number, export_quickroute(QuickRoute)).

export_quickroute(QuickRoute) ->
    Routes = kz_json:get_list_value(<<"Routes">>, QuickRoute, []),
    kz_json:from_list([{<<"Routes">>, [export_route(Route) || Route <- Routes]}]).

export_route(Route) ->
    export_route(Route, kz_json:get_ne_binary_value(<<"Invite-Format">>, Route)).

export_route(Route, <<"endpoint">>) ->
    URI = kz_json:get_ne_binary_value(<<"Endpoint-URI">>, Route),
    [EndpointId, AccountId] = binary:split(URI, <<"@">>),
    kz_json:from_list([{<<"Endpoint-ID">>, EndpointId}
                      ,{<<"Account-ID">>, AccountId}
                      ]).

%% @doc add a quickroute for a number to an endpoint
-spec add_quickroute(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
add_quickroute(Number, AccountId, EndpointId) ->
    add_quickroute(Number, AccountId, EndpointId, ?DEFAULT_EXPIRY).

-spec add_quickroute(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary(), pos_integer()) -> 'ok'.
add_quickroute(Number, AccountId, EndpointId, Expiry) ->
    add_quickroute_routes(Number
                         ,to_dialplan_routes([kz_json:from_list([{<<"Account-ID">>, AccountId}
                                                                ,{<<"Endpoint-ID">>, EndpointId}
                                                                ])
                                             ])
                         ,Expiry
                         ).

-spec handle_quickroute(kapi_route:quickroute(), kz_term:proplist()) -> 'ok'.
handle_quickroute(QuickRoute, _Props) ->
    'true' = kapi_route:quickroute_v(QuickRoute),

    add_quickroute_routes(kz_json:get_ne_binary_value(<<"Number">>, QuickRoute)
                         ,to_dialplan_routes(kz_json:get_list_value(<<"Endpoints">>, QuickRoute))
                         ,kz_json:get_integer_value(<<"Expiry">>, QuickRoute, ?DEFAULT_EXPIRY)
                         ).

add_quickroute_routes(Number, Routes, ExpiryS) ->
    'ok' = kz_cache:store_local(cache_name()
                               ,cache_key(Number)
                               ,kz_json:from_list([{<<"Method">>, <<"bridge">>}
                                                  ,{<<"Routes">>, Routes}
                                                  ])
                               ),
    lager:info("cached quickroute for ~s for ~bs", [Number, ExpiryS]).

to_dialplan_routes(Endpoints) ->
    [to_dialplan_route(Endpoint) || Endpoint <- Endpoints].

to_dialplan_route(Endpoint) ->
    <<AccountId/binary>> = kz_json:get_ne_binary_value(<<"Account-ID">>, Endpoint),
    <<EndpointId/binary>> = kz_json:get_ne_binary_value(<<"Endpoint-ID">>, Endpoint),
    kz_json:from_list([{<<"Endpoint-URI">>, <<EndpointId/binary, "@", AccountId/binary>>}
                      ,{<<"Invite-Format">>, <<"endpoint">>}
                      ]).

cache_key(Number) -> ?CACHE_KEY(Number).

-spec handle_quickroutes_query(kapi_route:quickroutes_query(), kz_term:proplist()) -> 'ok'.
handle_quickroutes_query(Req, _Props) ->
    'true' = kapi_route:query_quickroutes_req_v(Req),
    AccountId = kz_json:get_ne_binary_value(<<"Account-ID">>, Req),

    AccountQRs = kz_cache:filter_local(cache_name(), fun(_CacheKey, CacheValue) -> filter_quickroutes(AccountId, CacheValue) end),
    lager:info("account ~s qrs: ~p", [AccountId, AccountQRs]),
    quickroutes_resp(Req, AccountQRs).

filter_quickroutes(AccountId, QuickRoute) ->
    lists:any(fun(Route) -> does_route_matches_account(AccountId, Route) end
             ,kz_json:get_list_value(<<"Routes">>, QuickRoute, [])
             ).

does_route_matches_account(AccountId, Route) ->
    case binary:split(kz_json:get_ne_binary_value(<<"Endpoint-URI">>, Route), <<"@">>) of
        [_EndpointId, AccountId] -> 'true';
        _ -> 'false'
    end.

-spec quickroutes_resp(kapi_route:quickroutes_query(), kz_json:objects()) -> 'ok'.
quickroutes_resp(Req, QuickRoutes) ->
    Resp = [{<<"Quickroutes">>, [export_quickroute(Number, QuickRoute)
                                 || {Number, QuickRoute} <- QuickRoutes
                                ]
            }
           ,{<<"Msg-ID">>, kz_api:msg_id(Req)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kapi_route:publish_query_quickroutes_resp(kz_api:server_id(Req), Resp).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->
    lager:info("started quickroute listener"),
    {'ok', #state{}}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'gen_listener', {'created_queue', _QueueNAme}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener', {'is_consuming', _IsConsuming}}, State) ->
    {'noreply', State};
handle_cast(_Msg, State) ->
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Info, State) ->
    lager:info("unhandled msg: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), kz_term:proplist()) -> gen_listener:handle_event_return().
handle_event(_JObj, _State) ->
    {'reply', []}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("quickroute listener terminating: ~p", [_Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
