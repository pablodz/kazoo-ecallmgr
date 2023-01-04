%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_discovery).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-export([discover/0]).

-export([enable/0, disable/0]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).

-type state() :: kz_time:start_time().

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    case kz_app_config:get_boolean(?APP, <<"enable_discovery_server">>, 'false') of
        'true' -> gen_server:start_link({'local', ?SERVER}, ?MODULE, [], []);
        'false' -> 'ignore'
    end.

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server
%%
%% @end
%%------------------------------------------------------------------------------
-spec init(list()) -> {'ok', state(), ?MILLISECONDS_IN_SECOND}.
init([]) ->
    lager:info("starting discovery"),
    enable_updates(),
    {'ok', kz_time:start_time(), ?MILLISECONDS_IN_SECOND}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, Startup) ->
    {'reply', {'error', 'not_implemented'}, Startup, next_timeout(kz_time:elapsed_s(Startup))}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast('enable', Startup) ->
    lager:warning("enable discovery updates"),
    enable_updates(),
    {'noreply', Startup, next_timeout(kz_time:elapsed_s(Startup))};
handle_cast('disable', Startup) ->
    lager:warning("disable discovery updates"),
    disable_updates(),
    {'noreply', Startup, next_timeout(kz_time:elapsed_s(Startup))};
handle_cast('discovery', Startup) ->
    lager:warning("starting discovery"),
    _ = discovery(),
    {'noreply', Startup, next_timeout(kz_time:elapsed_s(Startup))};
handle_cast(_Msg, Startup) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', Startup, next_timeout(kz_time:elapsed_s(Startup))}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info('timeout', Startup) ->
    _ = discovery(),
    {'noreply', Startup, next_timeout(kz_time:elapsed_s(Startup))};
handle_info({'bgok', _Id, _Result}, Startup) ->
    lager:info("background job ~s: ~s", [_Id, _Result]),
    {'noreply', Startup, next_timeout(kz_time:elapsed_s(Startup))};
handle_info(_Msg, Startup) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', Startup, next_timeout(kz_time:elapsed_s(Startup))}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(Reason, _Startup) ->
    lager:debug("ecallmgr discovery terminating after ~ps: ~p", [kz_time:elapsed_s(_Startup), Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed
%%
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, Startup, _Extra) ->
    {'ok', Startup}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec next_timeout(integer()) -> integer().
next_timeout(Elapsed)
  when Elapsed < ?SECONDS_IN_MINUTE * 5 -> ?MILLISECONDS_IN_SECOND;
next_timeout(Elapsed)
  when Elapsed < ?SECONDS_IN_MINUTE * 10 -> ?MILLISECONDS_IN_SECOND * 3;
next_timeout(Elapsed)
  when Elapsed < ?SECONDS_IN_MINUTE * 20 -> ?MILLISECONDS_IN_SECOND * 5;
next_timeout(_Elapsed) -> ?MILLISECONDS_IN_MINUTE.

sbc_acl_filter({_K, V}) ->
    kz_json:get_ne_binary_value(<<"network-list-name">>, V) =:= <<"authoritative">>.

sbc_cidr(_Key, JObj, Acc) ->
    [{kz_json:get_value(<<"cidr">>, JObj), kz_json:get_value(<<"ports">>, JObj, [])} | Acc].

sbc_cidrs(ACLs) ->
    SBCs = kz_json:filter(fun sbc_acl_filter/1, ACLs),
    lists:flatten(kz_json:foldl(fun sbc_cidr/3, [], SBCs)).

sbc_address_foldl(_, JObj, Acc) ->
    IP = kz_json:get_ne_binary_value(<<"address">>, JObj),
    Port = kz_json:get_integer_value(<<"port">>, JObj, 0),
    case props:get_value(IP, Acc, []) of
        [] -> [{IP, [Port]} | Acc];
        Ports -> props:set_value(IP, lists:usort([Port | Ports]), Acc)
    end.

sbc_addresses(#kz_node{roles=Roles}) ->
    Listeners = kz_json:get_json_value(<<"Listeners">>, props:get_value(<<"Proxy">>, Roles)),
    kz_json:foldl(fun sbc_address_foldl/3, [], Listeners).

sbc_node(#kz_node{node=Name}=Node) ->
    {kz_term:to_binary(Name), sbc_addresses(Node)}.

sbc_verify_ip({IP, Ports}, CIDRs) ->
    lists:any(fun({CIDR, CIDRPorts}) when is_list(CIDR) ->
                      lists:all(fun(CIDR_IP) -> kz_network_utils:verify_cidr(IP, CIDR_IP) end, CIDR)
                          andalso Ports -- CIDRPorts  =:= []
                          andalso CIDRPorts -- Ports =:= [];
                 ({CIDR, CIDRPorts}) ->
                      kz_network_utils:verify_cidr(IP, CIDR)
                          andalso CIDRPorts -- Ports =:= []
                          andalso Ports -- CIDRPorts  =:= []
              end, CIDRs).

sbc_discover({Node, IPs}, CIDRs, Acc) ->
    case lists:filter(fun(IP) -> not sbc_verify_ip(IP, CIDRs) end, IPs) of
        [] -> Acc;
        Filtered -> [{Node, Filtered} | Acc]
    end.

-spec filter_acls(kz_json:object()) -> kz_json:object().
filter_acls(ACLs) ->
    kz_json:filter(fun filter_acls_fun/1, ACLs).

-spec filter_acls_fun({kz_json:path(), kz_json:json_term()}) -> boolean().
filter_acls_fun({_Name, ACL}) ->
    kz_json:get_ne_binary_value(<<"authorizing_type">>, ACL) =:= 'undefined'.

sbc_acl(IPs) ->
    CIDRs = [kz_network_utils:to_cidr(IP) || {IP, _} <- IPs],

    kz_json:from_list([{<<"type">>, <<"allow">>}
                      ,{<<"network-list-name">>, ?FS_SBC_ACL_LIST}
                      ,{<<"cidr">>, CIDRs}
                      ,{<<"ports">>, lists:usort(lists:flatten([Ports || {_, Ports} <- IPs]))}
                      ]).

sbc_acls(Nodes) ->
    [{Node, sbc_acl(IPs)} || {Node, IPs} <- Nodes].

-spec sbc_discovery() -> 'ok'.
sbc_discovery() ->
    sbc_discovery(<<"default">>).

-spec sbc_discovery(kz_term:ne_binary()) -> 'ok'.
sbc_discovery(Node) ->
    case ecallmgr_fs_acls:system(Node) of
        {'error', Error} -> lager:warning("error fetching current acls - ~p", [Error]);
        CurrentACLs -> sbc_discovery(Node, CurrentACLs)
    end.

-spec sbc_discovery(kz_term:ne_binary(), kz_json:object()) -> 'ok'.
sbc_discovery(ConfigNode, CurrentACLs) ->
    ACLs = filter_acls(CurrentACLs),
    CIDRs = sbc_cidrs(ACLs),
    Nodes = [sbc_node(Node) || Node <- kz_nodes:with_role(<<"Proxy">>, 'true')],
    case lists:foldl(fun(A, C) -> sbc_discover(A, CIDRs, C) end, [], Nodes) of
        [] -> 'ok';
        Updates ->
            Names = lists:usort(lists:map(fun({Node, _}) -> Node end, Updates)),
            lager:debug("adding authoritative acls for ~s", [kz_binary:join(Names)]),
            ToUpdate = lists:filter(fun({Node, _IPs}) -> lists:member(Node, Names) end , Nodes),
            SBCACLs = sbc_acls(ToUpdate),
            NewAcls = kz_json:set_values(SBCACLs, CurrentACLs),
            maybe_update_acls('sbc', CurrentACLs, NewAcls, ConfigNode)
    end.

-spec media_discovery() -> 'ok'.
media_discovery() ->
    media_discovery(<<"default">>).

-spec media_discovery(kz_term:ne_binary()) -> 'ok'.
media_discovery(Node) ->
    case ecallmgr_fs_acls:system(Node) of
        {'error', Error} -> lager:warning("error fetching current acls - ~p", [Error]);
        CurrentACLs -> media_discovery(Node, CurrentACLs)
    end.

-spec media_discovery(kz_term:ne_binary(), kz_json:object()) -> 'ok'.
media_discovery(Node, CurrentACLs) ->
    Current = kz_json:filter(fun is_media_acl/1, filter_acls(CurrentACLs)),
    Discovered = media_nodes(),
    Diff = kz_json:diff(Discovered, Current),
    case kz_json:is_empty(Diff) of
        'true' -> 'ok';
        'false' ->
            Keys = kz_json:get_keys(Diff),
            Updated = kz_json:filter(fun({K, _V}) -> lists:member(K, Keys) end, Discovered),
            NewAcls = kz_json:set_values(kz_json:to_proplist(Updated), CurrentACLs),
            maybe_update_acls('media', CurrentACLs, NewAcls, Node)
    end.

-spec is_media_acl(tuple()) -> boolean().
is_media_acl({_K, JObj}) ->
    kz_json:get_ne_binary_value(<<"network-list-name">>, JObj) =:= <<"freeswitch">>.

-spec media_nodes() -> kz_json:object().
media_nodes() ->
    Nodes = [media_node(Node)
             || #kz_node{media_servers = MediaList} <- kz_nodes:nodes(),
                MediaList =/= [],
                Node <- MediaList
            ],
    UniqueNodes = lists:foldl(fun media_node_unique/2, [], Nodes),
    MediaNodes = [media_node_acl(Unique) || Unique <- UniqueNodes],
    kz_json:from_list(MediaNodes).

media_node({Node, Data}) ->
    {Node, media_node_ips(Data)}.

media_node_ips(Data) ->
    Interfaces = kz_json:get_json_value(<<"Interfaces">>, Data, kz_json:new()),
    kz_json:foldl(fun media_node_ip/3 , {[], []}, Interfaces).

media_node_ip(_InterfaceName, SIPInterface, Acc) ->
    case media_node_interface(SIPInterface) of
        {_, 'undefined'} -> Acc;
        {[], _} -> Acc;
        IPPort -> media_node_ip(IPPort, Acc)
    end.

media_node_interface(SIPInterface) ->
    {media_node_interface_ips(SIPInterface), media_node_interface_port(SIPInterface)}.

media_node_interface_ips(SIPInterface) ->
    Fields = [<<"sip-ip">>, <<"ext-sip-ip">>],
    InterfaceIPs = [kz_json:get_ne_binary_value([<<"info">>, Field], SIPInterface)
                    || Field <- Fields
                   ],
    lists:usort(props:filter_undefined(InterfaceIPs)).

media_node_interface_port(SIPInterface) ->
    case kz_json:get_ne_binary_value([<<"info">>, <<"url">>], SIPInterface) of
        'undefined' -> 'undefined';
        URI -> kzsip_uri:port(kzsip_uri:parse(URI))
    end.

media_node_ip({IPList, Port}, {IPs, Ports}) ->
    {lists:usort(IPList ++ IPs), lists:usort([Port | Ports])}.

media_node_unique({NodeName, {IPs, Ports}} = Node, Acc) ->
    case props:get_value(NodeName, Acc) of
        'undefined' -> [Node | Acc];
        {ExistingIPs, ExistingPorts} ->
            Info = {lists:usort(ExistingIPs ++ IPs), lists:usort(ExistingPorts ++ Ports)},
            props:set_value({NodeName, Info}, Acc)
    end.

-spec media_node_acl({kz_term:ne_binary(), {kz_term:ne_binaries(), [inet:port_number()]}}) ->
          {kz_term:ne_binary(), kz_json:object()} | 'undefined'.
media_node_acl({_Node, {[], _Ports}}) -> 'undefined';
media_node_acl({_Node, {_IPs, []}}) -> 'undefined';
media_node_acl({Node, {IPs, Ports}}) ->
    CIDRs = [<<IP/binary, "/32">> || IP <- IPs],
    ACL = kz_json:from_list([{<<"type">>, <<"allow">>}
                            ,{<<"network-list-name">>, <<"freeswitch">>}
                            ,{<<"cidr">>, CIDRs}
                            ,{<<"ports">>, Ports}
                            ]),
    {Node, ACL};
media_node_acl(_) -> 'undefined'.

-spec discover() -> 'ok'.
discover() ->
    gen_server:cast(?MODULE, 'discovery').

-spec enable() -> 'ok'.
enable() ->
    gen_server:cast(?MODULE, 'enable').

-spec disable() -> 'ok'.
disable() ->
    gen_server:cast(?MODULE, 'disable').

-spec discovery() -> 'ok'.
discovery() ->
    Routines = [fun sbc_discovery/0
               ,fun media_discovery/0
               ],
    lists:foreach(fun(F) -> F() end, Routines).

maybe_update_acls(Type, OldACLs, NewACLs, Node) ->
    update_acls(kz_json:are_equal(OldACLs, NewACLs), Type, NewACLs, Node).

update_acls('true', _Type, _NewACLs, _Node) -> 'ok';
update_acls('false', Type, NewACLs, Node) ->
    do_update_acls(should_update(), Type, NewACLs, Node).

do_update_acls('false', _Type, _NewACLs, _Node) ->
    lager:warning("NOT updating acls from discover process for ~s (disabled)", [_Type]);
do_update_acls('true', Type, NewACLs, Node) ->
    lager:warning("updating acls from discover process for ~s", [Type]),
    _ = kapps_config:set_node(?APP_NAME, <<"acls">>, NewACLs, Node),
    ecallmgr_maintenance:publish_reload_acls(),
    lager:debug("published reload of ACLs").

-spec should_update() -> boolean().
should_update() ->
    kz_term:is_true(get_updates()).

get_updates() ->
    erlang:get('discovery_updates_enabled').

enable_updates() ->
    erlang:put('discovery_updates_enabled', 'true').

disable_updates() ->
    erlang:put('discovery_updates_enabled', 'false').
