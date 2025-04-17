%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2025, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_acls).

-export([get/0, get/1
        ,system/0, system/1
        ,edge/0, edge/1
        ,system_config_acls/1
        ,trusted_acls/0, trusted_acls/1
        ,media_acls/0, media_acls/1
        ,authoritative_acls/0, authoritative_acls/1
        ]).

-compile({'no_auto_import', [get/1]}).

-include("ecallmgr.hrl").

-define(REQUEST_TIMEOUT
       ,kapps_config:get_integer(?APP_NAME
                                ,<<"acl_request_timeout_ms">>
                                ,2 * ?MILLISECONDS_IN_SECOND
                                )
       ).
-define(REQUEST_TIMEOUT_FUDGE
       ,kapps_config:get_integer(?APP_NAME
                                ,<<"acl_request_timeout_fudge_ms">>
                                ,100
                                )
       ).
-define(IP_REGEX, <<"^(\\d{1,3}\\\.\\d{1,3}\\\.\\d{1,3}\\\.\\d{1,3}).*">>).
-define(ACL_RESULT(IP, ACL), {'acl', IP, ACL}).
-define(ACL_RESULT_MERGE(ACL), {'acl_merge', ACL}).

-type acls() :: kz_json:object().
-type acl_builder_fun() :: fun((pid(), kzd_resources:doc(), kz_term:ne_binaries()) -> 'ok').

%%------------------------------------------------------------------------------
%% @doc Fetches the ACLs
%% 1. from system_config
%% 2. auth-by-IP devices
%% 3. local resources
%% 4. global resources
%%
%% @end
%%------------------------------------------------------------------------------
-spec get() -> acls().
get() ->
    Node = kz_term:to_binary(node()),
    get(Node).

-spec get(atom() | kz_term:ne_binary()) -> acls().
get(Node) ->
    Routines = [fun collect_system_config_acls/2
               ,fun offnet_resources/1
               ,fun local_resources/1
               ,fun sip_auth_ips/1
               ,fun collect_media_acls/1
               ],
    Args = [self(), Node],
    PidRefs = collector_spawn(Routines, Args),
    {'ok', Master} = kapps_util:get_master_account_id(),
    lager:debug("collecting ACLs in ~p", [PidRefs]),
    collect(Master, kz_json:new(), PidRefs).

-spec media_acls() -> acls().
media_acls() ->
    media_acls(<<"default">>).

-spec media_acls(atom() | kz_term:ne_binary()) -> acls().
media_acls(Node) ->
    case kapps_config:fetch_current(?APP_NAME, <<"acls">>, kz_json:new(), Node) of
        {'error', Error} ->
            lager:warning("error getting system acls : ~p", [Error]),
            kz_json:new();
        JObj -> kz_json:filter(fun is_media_acl/1, JObj)
    end.

-spec is_media_acl(tuple()) -> boolean().
is_media_acl({_K, JObj}) ->
    <<"freeswitch">> =:= kzd_acls:network_list_name(JObj).

-spec collect_media_acls(pid()) -> 'ok'.
collect_media_acls(Collector) ->
    kz_json:foreach(fun({Host, ACL}) ->
                            Collector ! ?ACL_RESULT(Host, ACL)
                    end
                   ,media_acls()
                   ).

-spec edge() -> acls().
edge() ->
    Node = kz_term:to_binary(node()),
    edge(Node).

-spec edge(atom() | kz_term:ne_binary()) -> acls().
edge(Node) ->
    Routines = [fun collect_trusted_acls/2
               ,fun offnet_resources/1
               ,fun local_resources/1
               ,fun sip_auth_ips/1
               ],
    Args = [self(), Node],
    {'ok', Master} = kapps_util:get_master_account_id(),
    PidRefs = collector_spawn(Routines, Args),
    lager:debug("collecting ACLs in ~p", [PidRefs]),
    token(cidrs(collect(Master, kz_json:new(), PidRefs))).

%%------------------------------------------------------------------------------
%% @doc Fetches just the system_config ACLs
%% @end
%%------------------------------------------------------------------------------
-spec system() -> acls() | {'error', any()}.
system() ->
    system(kz_term:to_binary(node())).

-spec system(atom() | kz_term:ne_binary()) -> acls() | {'error', any()}.
system(Node) ->
    kapps_config:fetch_current(?APP_NAME, <<"acls">>, kz_json:new(), Node).

-spec collector_spawn(list(), list()) -> kz_term:pid_refs().
collector_spawn(Routines, Args) ->
    [collector_routine_spawn(Routine, Args) || Routine <- Routines].

collector_routine_spawn(Routine, [Collector | _])
  when is_function(Routine, 1) ->
    kz_process:spawn_monitor(Routine, [Collector]);
collector_routine_spawn(Routine, [Collector , Arg2 | _])
  when is_function(Routine, 2) ->
    kz_process:spawn_monitor(Routine, [Collector, Arg2]);
collector_routine_spawn(Routine, [Collector , Arg2, Arg3 | _])
  when is_function(Routine, 3) ->
    kz_process:spawn_monitor(Routine, [Collector, Arg2, Arg3]).

-spec collect(kz_term:ne_binary(), kz_json:object(), kz_term:pid_refs()) ->
          kz_json:object().
collect(Master, ACLs, PidRefs) ->
    collect(Master, ACLs, PidRefs, request_timeout(), 0).

-spec request_timeout() -> pos_integer().
request_timeout() ->
    ?REQUEST_TIMEOUT + ?REQUEST_TIMEOUT_FUDGE.

-spec collect(kz_term:ne_binary(), kz_json:object(), kz_term:pid_refs(), timeout(), integer()) ->
          kz_json:object().
collect(_Master, ACLs, [], _Timeout, 0) ->
    lager:debug("acls built with ~p ms to spare", [_Timeout]),
    ACLs;
collect(_Master, _ACLs, [], _Timeout, Errors) ->
    throw(io_lib:format("got ~b error(s) collecting ACLs", [Errors]));
collect(_Master, _ACLs, _PidRefs, Timeout, _Errors) when Timeout < 0 ->
    throw("timed out waiting for ACLs");
collect(Master, ACLs, PidRefs, Timeout, Errors) ->
    Start = kz_time:start_time(),

    receive
        ?ACL_RESULT(ACLName, ACL) ->
            collect(Master
                   ,process_collect_result(Master, ACLName, ACL, ACLs)
                   ,PidRefs
                   ,kz_time:decr_timeout(Timeout, Start)
                   ,Errors
                   );
        ?ACL_RESULT_MERGE(ACL) ->
            lager:info("merging acl"),
            collect(Master
                   ,kz_json:merge(ACL, ACLs)
                   ,PidRefs
                   ,kz_time:decr_timeout(Timeout, Start)
                   ,Errors
                   );
        {'DOWN', Ref, 'process', Pid, Reason} ->
            collect_continue(Master, ACLs, PidRefs, Ref, Pid, Reason, kz_time:decr_timeout(Timeout, Start), Errors)
    after Timeout ->
            throw("timed out collecting acls")
    end.

process_collect_result(Master, ACLName, ACL, ACLs) ->
    case kz_json:get_value(ACLName, ACLs) of
        'undefined' -> process_collect_result_add_acl(ACLName, ACL, ACLs);
        Existing -> process_collect_result_check_existing_acl(Master, ACLName, ACL, ACLs, Existing)
    end.

process_collect_result_add_acl(ACLName, ACL, ACLs) ->
    NetworkName = kzd_acls:network_list_name(ACL),
    lager:info("adding acl for '~s' to network list ~s", [ACLName, NetworkName]),
    kz_json:set_value(ACLName, ACL, ACLs).

process_collect_result_check_existing_acl(Master, ACLName, ACL, ACLs, Existing) ->
    NewAccountId = kz_json:get_ne_binary_value(<<"account_id">>, ACL),
    ExistingAccountId = kz_json:get_ne_binary_value(<<"account_id">>, Existing),
    case NewAccountId =:= Master
        orelse ExistingAccountId =/= Master
    of
        'true' -> process_collect_result_add_acl(ACLName, ACL, ACLs);
        'false' -> ACLs
    end.

collect_continue(Master, ACLs, PidRefs, Ref, Pid, Reason, Timeout, Errors) ->
    case lists:keytake(Pid, 1, PidRefs) of
        'false' ->
            collect(Master, ACLs, PidRefs, Timeout, Errors);
        {'value', {Pid, Ref}, NewPidRefs} ->
            lager:info("collect process ~p ended => ~p", [Pid, Reason]),
            collect(Master, ACLs, NewPidRefs, Timeout, collect_errors(Reason, Errors))
    end.

collect_errors('normal', Errors) -> Errors;
collect_errors(_, Errors) -> Errors + 1.

-spec collect_system_config_acls(pid(), atom() | kz_term:ne_binary()) -> 'ok'.
collect_system_config_acls(Collector, Node) ->
    ACLs = system_config_acls(Node),
    Collector ! ?ACL_RESULT_MERGE(ACLs),
    'ok'.

-spec system_config_acls(atom() | kz_term:ne_binary()) -> acls().
system_config_acls(Node) ->
    case kapps_config:fetch_current(?APP_NAME, <<"acls">>, kz_json:new(), Node) of
        {'error', Error} ->
            throw(io_lib:format("error getting system acls : ~s", [Error]));
        JObj -> resolve(JObj)
    end.

resolve(JObj) ->
    kz_json:map(fun resolve/2, JObj).

resolve(K, JObj) ->
    CIDR = kzd_acls:cidr(JObj),
    {K, kzd_acls:set_cidr(JObj, maybe_resolve_cidr(CIDR))}.

maybe_resolve_cidr(CIDRS)
  when is_list(CIDRS) ->
    [maybe_resolve_cidr(CIDR) || CIDR <- CIDRS];
maybe_resolve_cidr(CIDR)
  when is_binary(CIDR) ->
    case is_cidr(CIDR) of
        'true' -> CIDR;
        'false' -> resolve_cidr(CIDR)
    end.

resolve_cidr(CIDR) ->
    case kz_network_utils:is_ipv4(CIDR) of
        'true' ->
            kz_network_utils:to_cidr(CIDR);
        'false' ->
            IPs = kz_network_utils:resolve(CIDR, ecallmgr_util:get_resolve_options()),
            [kz_network_utils:to_cidr(IP) || IP <- IPs]
    end.

-spec is_cidr(kz_term:text()) -> boolean().
is_cidr(Address) ->
    kz_network_utils:is_cidr(Address, 'true').

-spec authoritative_acls() -> acls().
authoritative_acls() ->
    authoritative_acls(<<"default">>).

-spec authoritative_acls(atom() | kz_term:ne_binary()) -> acls().
authoritative_acls(Node) ->
    case kapps_config:fetch_current(?APP_NAME, <<"acls">>, kz_json:new(), Node) of
        {'error', Error} ->
            lager:warning("error getting system acls : ~p", [Error]),
            kz_json:new();
        JObj -> kz_json:filter(fun is_authoritative_acl/1, JObj)
    end.

-spec is_authoritative_acl(tuple()) -> boolean().
is_authoritative_acl({_K, JObj}) ->
    kzd_acls:network_list_name(JObj) =:= <<"authoritative">>.

-spec trusted_acls() -> acls().
trusted_acls() ->
    Node = kz_term:to_binary(node()),
    trusted_acls(Node).

-spec trusted_acls(atom() | kz_term:ne_binary()) -> acls().
trusted_acls(Node) ->
    case kapps_config:fetch_current(?APP_NAME, <<"acls">>, kz_json:new(), Node) of
        {'error', Error} -> throw(io_lib:format("error fetch trusted acls : ~s", Error));
        JObj -> resolve(kz_json:filtermap(fun trusted_acl/2, JObj))
    end.

-spec collect_trusted_acls(pid(), atom() | kz_term:ne_binary()) -> 'ok'.
collect_trusted_acls(Collector, Node) ->
    lager:debug("fetching trusted ACLs for node ~s", [Node]),
    ACLs = trusted_acls(Node),
    lager:debug("ACLs fetch, delivering to ~p", [Collector]),
    Collector ! ?ACL_RESULT_MERGE(ACLs),
    'ok'.

-spec trusted_default_authorization_id() -> kz_term:ne_binary().
trusted_default_authorization_id() ->
    kapps_config:get_ne_binary(?APP_NAME, <<"trusted_authorizing_id">>, kz_binary:rand_hex(16)).

-spec trusted_acl(kz_term:ne_binary(), kz_json:object()) -> boolean() | {'true', kz_json:object()}.
trusted_acl(K, V) ->
    case filter_trusted_acl({K,V}) of
        'false' -> 'false';
        'true' ->
            {'ok', Master} = kapps_util:get_master_account_id(),
            AccountId = kz_json:get_ne_binary_value(<<"account_id">>, V, Master),
            AuthorizingId = kz_json:get_ne_binary_value(<<"authorizing_id">>, V, trusted_default_authorization_id()),
            KVs = [{<<"account_id">>, AccountId}
                  ,{<<"authorizing_id">>, AuthorizingId}
                  ],
            JObj = kz_json:set_values(KVs, V),
            {'true', {K, JObj}}
    end.

-spec filter_trusted_acl(tuple()) -> boolean().
filter_trusted_acl(ACL) ->
    is_trusted_acl(ACL)
        andalso is_allowed(ACL).

-spec is_trusted_acl(tuple()) -> boolean().
is_trusted_acl({_K, JObj}) ->
    kzd_acls:network_list_name(JObj) =:= <<"trusted">>.

-spec is_allowed(tuple()) -> boolean().
is_allowed({_K, JObj}) ->
    kzd_acls:type(JObj, 'undefined') =:= <<"allow">>.

-spec sip_auth_ips(pid()) -> 'ok'.
sip_auth_ips(Collector) ->
    ViewOptions = [],
    StartTime = kz_time:start_time(),
    case kz_datamgr:get_results(?KZ_SIP_DB, <<"credentials/lookup_by_ip">>, ViewOptions) of
        {'error', _R} ->
            throw(io_lib:format("unable to get view results for auth-by-ip devices: ~s", [_R]));
        {'ok', JObjs} ->
            handle_sip_auth_results(Collector, StartTime, JObjs)
    end.

handle_sip_auth_results(Collector, StartTime, JObjs) ->
    {{RawIPs, IPCount}
    ,{RawHosts, HostCount}
    } = lists:foldl(fun needs_resolving/2
                   ,{{[], 0}, {[], 0}}
                   ,JObjs
                   ),
    lager:debug("found ~p IPs and ~p hosts", [IPCount, HostCount]),

    _ = report_sip_auth_ips(Collector, RawIPs),

    _ = report_sip_auth_hosts(Collector, RawHosts),
    lager:debug("finished SIP auth results in ~pms", [kz_time:elapsed_ms(StartTime)]).

report_sip_auth_ips(Collector, RawIPs) ->
    _ = [handle_sip_auth_result(Collector, JObj, IPs)
         || {IPs, JObj} <- RawIPs
        ].

report_sip_auth_hosts(Collector, RawHosts) ->
    PidRefs = [kz_process:spawn_monitor(fun resolve_hostname/4
                                       ,[Collector
                                        ,{Host, 'undefined'}
                                        ,JObj
                                        ,fun handle_sip_auth_result/3
                                        ]
                                       )
               || {Host, JObj} <- RawHosts
              ],
    lager:debug("started sip auth host resolvers: ~p", [[P || {P, _} <- PidRefs]]),
    wait_for_pid_refs(PidRefs).

-type needs_acc() :: {{kz_term:ne_binaries(), non_neg_integer()} %% IPs
                     ,{kz_term:ne_binaries(), non_neg_integer()} %% Hostnames
                     }.
-spec needs_resolving(kz_json:object(), needs_acc()) -> needs_acc().
needs_resolving(JObj, {{IPs, IPCount}, {ToResolve, HostCount}}) ->
    IP = kz_json:get_ne_binary_value(<<"key">>, JObj),
    case kz_network_utils:is_ipv4(IP) of
        'true' -> {{[{[IP], JObj}|IPs], IPCount+1}, {ToResolve, HostCount}};
        'false' -> {{IPs, IPCount}, {[{IP, JObj} | ToResolve], HostCount+1}}
    end.

-spec wait_for_pid_refs(kz_term:pid_refs()) -> 'ok'.
wait_for_pid_refs([]) ->
    lager:info("no workers started");
wait_for_pid_refs([_|_]=PidRefs) ->
    wait_for_pid_refs(PidRefs, ?REQUEST_TIMEOUT, 0).

-spec wait_for_pid_refs(kz_term:pid_refs(), timeout(), non_neg_integer()) -> 'ok'.
wait_for_pid_refs([], _Timeout, _Total) ->
    lager:debug("handled ~p workers", [_Total]);
wait_for_pid_refs(_PidRefs, Timeout, _Total) when Timeout < 0 ->
    lager:debug("processed ~p workers and timed out on ~p left", [_Total, length(_PidRefs)]);
wait_for_pid_refs(PidRefs, Timeout, Total) ->
    Start = kz_time:start_time(),
    receive
        {'DOWN', Ref, 'process', Pid, Reason} ->
            handle_down_pid_ref(PidRefs, Timeout, Total, Start, Pid, Ref, Reason)
    after Timeout ->
            lager:info("timed out after processing ~p workers; still waiting on ~p workers"
                      ,[Total, length(PidRefs)]
                      ),
            lager:debug("workers left: ~p", [PidRefs])
    end.

handle_down_pid_ref(PidRefs, Timeout, Total, Start, Pid, Ref, Reason) ->
    case lists:keytake(Pid, 1, PidRefs) of
        'false' ->
            wait_for_pid_refs(PidRefs, kz_time:decr_timeout(Timeout, Start), Total);
        {'value', {Pid, Ref}, NewPidRefs} ->
            maybe_log_down_reason(Pid, Reason),
            wait_for_pid_refs(NewPidRefs, kz_time:decr_timeout(Timeout, Start), Total+1)
    end.

maybe_log_down_reason(_Pid, 'normal') -> 'ok';
maybe_log_down_reason(Pid, Reason) -> lager:info("worker pid ~p died: ~p", [Pid, Reason]).

-spec resolve_hostname(pid(), {kz_term:ne_binary(), kz_term:api_integer()}, kzd_resources:doc(), acl_builder_fun()) -> 'ok'.
resolve_hostname(Collector, {ResolveMe, Port}, Resource, ACLBuilderFun) ->
    lager:debug("attempting to resolve '~s':~p", [ResolveMe, Port]),
    StrippedHost = hd(binary:split(ResolveMe, <<";">>)),

    case binary:split(StrippedHost, <<":">>) of
        [StrippedHost] ->
            resolve_hostname(Collector, ResolveMe, Resource, ACLBuilderFun, StrippedHost, Port);
        [Host, HardcodedPort] ->
            lager:info("host ~s comes with hardcoded port ~s, overriding ~p"
                      ,[Host, HardcodedPort, Port]
                      ),
            resolve_hostname(Collector, ResolveMe, Resource, ACLBuilderFun, Host, kz_term:to_integer(HardcodedPort))
    end.

-spec resolve_hostname(pid(), kz_term:ne_binary(), kzd_resources:doc(), acl_builder_fun(), kz_term:ne_binary(), kz_term:api_integer()) -> 'ok'.
resolve_hostname(Collector, ResolveMe, Resource, ACLBuilderFun, Host, Port) ->
    case kz_network_utils:is_ipv4(Host) of
        'true' ->
            %% Host is a raw IPv4
            ACLBuilderFun(Collector, Resource, [{Host, Port}]);
        'false' ->
            case kz_network_utils:resolve(Host, ecallmgr_util:get_resolve_options()) of
                [] ->
                    lager:debug("no IPs resolved for host ~s, checking for raw IP", [Host]),
                    maybe_capture_ip(Collector, ResolveMe, Resource, ACLBuilderFun, Port);
                IPs ->
                    ACLBuilderFun(Collector, Resource, [{IP, Port} || IP <- IPs]),
                    lager:debug("resolved '~s' (~s) for ~p: '~s'"
                               ,[Host, ResolveMe, Collector, kz_binary:join(IPs, <<"','">>)]
                               )
            end
    end.

-spec maybe_capture_ip(pid(), kz_term:ne_binary(), kzd_resources:doc(), acl_builder_fun(), kz_term:api_integer()) -> 'ok'.
maybe_capture_ip(Collector, CaptureMe, Resource, ACLBuilderFun, Port) ->
    case re:run(CaptureMe, ?IP_REGEX, [{'capture', 'all', 'binary'}]) of
        {'match', [_All, IP]} ->
            ACLBuilderFun(Collector, Resource, [{IP, Port}]),
            lager:debug("captured '~s' from ~s port ~p", [IP, CaptureMe, Port]);
        'nomatch' ->
            lager:debug("failed to find IP at start of '~s'", [CaptureMe])
    end.

-spec handle_sip_auth_result(pid(), kz_json:object(), kz_term:ne_binaries()) -> 'ok'.
handle_sip_auth_result(Collector, JObj, IPs) ->
    AccountId = kz_json:get_value([<<"value">>, <<"account_id">>], JObj),
    AuthorizingId = kz_doc:id(JObj),
    AuthorizingType = kz_json:get_value([<<"value">>, <<"authorizing_type">>], JObj),
    add_trusted_objects(Collector, AccountId, AuthorizingId, AuthorizingType, IPs).

-spec local_resources(pid()) -> 'ok'.
local_resources(Collector) ->
    ViewOptions = ['include_docs'],
    case kz_datamgr:get_results(?KZ_SIP_DB, <<"resources/listing_active_by_weight">>, ViewOptions) of
        {'error', _R} ->
            throw(io_lib:format("unable to get view results for local active resources: ~s", [_R]));
        {'ok', []} ->
            lager:info("no local resources in ~s", [?KZ_SIP_DB]);
        {'ok', JObjs} ->
            handle_resource_results(Collector, JObjs)
    end.

-spec offnet_resources(pid()) -> 'ok'.
offnet_resources(Collector) ->
    ViewOptions = ['include_docs'],
    case kz_datamgr:get_results(?KZ_OFFNET_DB, <<"resources/listing_active_by_weight">>, ViewOptions) of
        {'error', _R} ->
            throw(io_lib:format("unable to get view results for offnet active resources : ~s", [_R]));
        {'ok', ViewResources} ->
            lager:debug("fetch offnet resources"),
            handle_resource_results(Collector, ViewResources)
    end.

-spec handle_resource_results(pid(), kz_json:objects()) -> 'ok'.
handle_resource_results(Collector, ViewResources) ->
    PidRefs = [kz_process:spawn_monitor(fun handle_resource_view_result/2
                                       ,[Collector, ViewResource]
                                       )
               || ViewResource <- ViewResources
              ],
    wait_for_pid_refs(PidRefs),
    lager:debug("handled ~p resources", [length(ViewResources)]).

-spec handle_resource_view_result(pid(), kz_json:object()) -> 'ok'.
handle_resource_view_result(Collector, ViewResource) ->
    Resource = kz_json:get_json_value(<<"doc">>, ViewResource),

    ServerPidRefs = resource_server_ips(Collector, Resource),
    resource_inbound_ips(Collector, Resource), %% direct IPs sent to Collector

    wait_for_pid_refs(ServerPidRefs).

%% IPs could be [IP] | [{IP, Port}]
-spec handle_resource_result(pid(), kzd_resources:doc(), kz_term:ne_binaries() | kz_term:proplist()) -> 'ok'.
handle_resource_result(Collector, Resource, IPs) ->
    AuthorizingId = kz_doc:id(Resource),
    {'ok', Master} = kapps_util:get_master_account_id(),
    AccountId = kz_doc:account_id(Resource, Master),
    add_trusted_objects(Collector, AccountId, AuthorizingId, <<"resource">>, IPs).

-spec resource_inbound_ips(pid(), kzd_resources:doc()) -> 'ok'.
resource_inbound_ips(Collector, Resource) ->
    lists:foreach(fun(InboundIP) ->
                          handle_resource_result(Collector, Resource, [{InboundIP, 'undefined'}])
                  end
                 ,kz_json:get_list_value(<<"inbound_ips">>, Resource, [])
                 ).

-spec resource_server_ips(pid(), kzd_resources:doc()) -> kz_term:pid_refs().
resource_server_ips(Collector, Resource) ->
    lists:foldl(fun(Gateway, Acc) -> maybe_collect_ips_and_hosts(Collector, Resource, Gateway, Acc) end
               ,[]
               ,kzd_resources:gateways(Resource, [])
               ).

maybe_collect_ips_and_hosts(Collector, Resource, Gateway, Acc) ->
    case kz_json:get_ne_binary_value(<<"endpoint_type">>, Gateway) =:= <<"sip">>
        andalso kz_json:is_true(<<"enabled">>, Gateway, 'false')
    of
        'false' -> Acc;
        'true' ->
            collect_ips_and_hosts(Collector, Resource, Gateway, Acc)
    end.

collect_ips_and_hosts(Collector, Resource, Gateway, Acc) ->
    Server = kz_json:get_ne_binary_value(<<"server">>, Gateway),
    Port = kz_json:get_integer_value(<<"port">>, Gateway),

    case kz_network_utils:is_ip(Server) of
        'true' ->
            handle_resource_result(Collector, Resource, [{Server, Port}]),
            Acc;
        'false' ->
            PidRef = kz_process:spawn_monitor(fun resolve_hostname/4
                                             ,[Collector
                                              ,{Server, Port}
                                              ,Resource
                                              ,fun handle_resource_result/3
                                              ]
                                             ),
            [PidRef | Acc]
    end.

-spec add_trusted_objects(pid(), kz_term:api_binary(), kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binaries() | kz_term:proplist()) -> 'ok'.
add_trusted_objects(Collector, AccountId, AuthorizingId, AuthorizingType, IPs) ->
    BaseACL = kz_json:from_list(
                [{<<"type">>, <<"allow">>}
                ,{<<"network-list-name">>, <<"trusted">>}
                ,{<<"account_id">>, AccountId}
                ,{<<"authorizing_id">>, AuthorizingId}
                ,{<<"authorizing_type">>, AuthorizingType}
                ]),
    lists:foreach(fun(IP) -> add_trusted_object(Collector, BaseACL, IP) end, IPs).

add_trusted_object(Collector, BaseACL, {IP, 'undefined'}) ->
    add_trusted_object(Collector, BaseACL, IP);
add_trusted_object(Collector, BaseACL, {IP, Port}) ->
    ACLName = <<IP/binary, ":", (kz_term:to_binary(Port))/binary>>,
    ACL = kz_json:set_values([{<<"cidr">>, <<IP/binary, "/32">>}
                             ,{<<"ports">>, [Port]}
                             ]
                            ,BaseACL
                            ),
    Collector ! ?ACL_RESULT(ACLName, ACL);
add_trusted_object(Collector, BaseACL, <<IP/binary>>) ->
    ACL = kz_json:set_value(<<"cidr">>, <<IP/binary, "/32">>, BaseACL),
    Collector ! ?ACL_RESULT(IP, ACL).

-spec cidrs(kz_json:object()) -> kz_json:object().
cidrs(JObj) ->
    kz_json:map(fun cidrs/2, JObj).

-spec cidrs(kz_term:ne_binary(), kz_json:object()) -> boolean() | {'true', kz_json:object()}.
cidrs(IP, ACL) ->
    CIDRs = case kz_json:get_list_value(<<"cidr">>, ACL) of
                'undefined' -> [kz_json:get_ne_binary_value(<<"cidr">>, ACL)];
                List -> List
            end,
    KVs = [{<<"cidrs">>, CIDRs}
          ,{<<"cidr">>, 'null'}
          ,{<<"network-list-name">>, 'null'}
          ,{<<"type">>, 'null'}
          ,{<<"ports">>, kz_json:get_list_value(<<"ports">>, ACL)}
          ],
    {IP, kz_json:set_values(KVs, ACL)}.


-spec token(kz_json:object()) -> kz_json:object().
token(JObj) ->
    kz_json:map(fun token/2, JObj).

-spec token(kz_term:ne_binary(), kz_json:object()) -> boolean() | {'true', kz_json:object()}.
token(K, V) ->
    KVs = [{<<"network-list-name">>, 'null'}
          ,{<<"type">>, 'null'}
          ,{<<"token">>, list_to_binary([kz_json:get_ne_binary_value(<<"authorizing_id">>, V)
                                        ,"@"
                                        ,kz_json:get_ne_binary_value(<<"account_id">>, V)
                                        ])
           }
          ,{<<"authorizing_id">>, 'null'}
          ,{<<"authorizing_type">>, 'null'}
          ,{<<"account_id">>, 'null'}
          ],
    {K, kz_json:set_values(KVs, V)}.
