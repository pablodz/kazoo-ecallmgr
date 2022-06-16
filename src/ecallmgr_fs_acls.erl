%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2022, 2600Hz
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
    lager:debug("collecting ACLs in ~p", [PidRefs]),
    collect(kz_json:new(), PidRefs).

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
    PidRefs = collector_spawn(Routines, Args),
    lager:debug("collecting ACLs in ~p", [PidRefs]),
    token(cidrs(collect(kz_json:new(), PidRefs))).

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

-spec collect(kz_json:object(), kz_term:pid_refs()) ->
          kz_json:object().
collect(ACLs, PidRefs) ->
    collect(ACLs, PidRefs, request_timeout(), 0).

-spec request_timeout() -> pos_integer().
request_timeout() ->
    ?REQUEST_TIMEOUT + ?REQUEST_TIMEOUT_FUDGE.

-spec collect(kz_json:object(), kz_term:pid_refs(), timeout(), integer()) ->
          kz_json:object().
collect(ACLs, [], _Timeout, 0) ->
    lager:debug("acls built with ~p ms to spare", [_Timeout]),
    ACLs;
collect(_ACLs, [], _Timeout, Errors) ->
    throw(io_lib:format("got ~b error(s) collecting ACLs", [Errors]));
collect(_ACLs, _PidRefs, Timeout, _Errors) when Timeout < 0 ->
    throw("timed out waiting for ACLs");
collect(ACLs, PidRefs, Timeout, Errors) ->
    Start = kz_time:start_time(),

    receive
        ?ACL_RESULT(ACLName, ACL) ->
            lager:info("adding acl for '~s' to network list ~s"
                      ,[ACLName, kzd_acls:network_list_name(ACL)]
                      ),
            collect(kz_json:set_value(ACLName, ACL, ACLs)
                   ,PidRefs
                   ,kz_time:decr_timeout(Timeout, Start)
                   ,Errors
                   );
        ?ACL_RESULT_MERGE(ACL) ->
            lager:info("merging acl"),
            collect(kz_json:merge(ACL, ACLs)
                   ,PidRefs
                   ,kz_time:decr_timeout(Timeout, Start)
                   ,Errors
                   );
        {'DOWN', Ref, 'process', Pid, Reason} ->
            collect_continue(ACLs, PidRefs, Ref, Pid, Reason, kz_time:decr_timeout(Timeout, Start), Errors)
    after Timeout ->
            throw("timed out collecting acls")
    end.

collect_continue(ACLs, PidRefs, Ref, Pid, Reason, Timeout, Errors) ->
    case lists:keytake(Pid, 1, PidRefs) of
        'false' ->
            collect(ACLs, PidRefs, Timeout, Errors);
        {'value', {Pid, Ref}, NewPidRefs} ->
            lager:info("collect process ~p ended => ~p", [Pid, Reason]),
            collect(ACLs, NewPidRefs, Timeout, collect_errors(Reason, Errors))
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
    ACLs = trusted_acls(Node),
    Collector ! ?ACL_RESULT_MERGE(ACLs),
    'ok'.

-spec trusted_acl(kz_term:ne_binary(), kz_json:object()) -> boolean() | {'true', kz_json:object()}.
trusted_acl(K, V) ->
    case filter_trusted_acl({K,V}) of
        'false' -> 'false';
        'true' ->
            {'ok', Master} = kapps_util:get_master_account_id(),
            KVs = [{<<"account_id">>, kz_json:get_ne_binary_value(<<"account_id">>, V, Master)}
                  ,{<<"authorizing_id">>, kz_json:get_ne_binary_value(<<"authorizing_id">>, V, kz_binary:rand_hex(16))}
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
    case kz_datamgr:get_results(?KZ_SIP_DB, <<"credentials/lookup_by_ip">>, ViewOptions) of
        {'error', _R} ->
            throw(io_lib:format("unable to get view results for auth-by-ip devices: ~s", [_R]));
        {'ok', JObjs} ->
            {RawIPs, RawHosts} = lists:foldl(fun needs_resolving/2, {[], []}, JObjs),

            _ = report_sip_auth_ips(Collector, RawIPs),

            _ = report_sip_auth_hosts(Collector, RawHosts)
    end.

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
    wait_for_pid_refs(PidRefs).

-spec needs_resolving(kz_json:object(), {list(), list()}) -> {list(), list()}.
needs_resolving(JObj, {IPs, ToResolve}) ->
    IP = kz_json:get_value(<<"key">>, JObj),
    case kz_network_utils:is_ipv4(IP) of
        'true' -> {[{[IP], JObj}|IPs], ToResolve};
        'false' -> {IPs, [{IP, JObj} | ToResolve]}
    end.

-spec wait_for_pid_refs(kz_term:pid_refs()) -> 'ok'.
wait_for_pid_refs(PidRefs) ->
    wait_for_pid_refs(PidRefs, ?REQUEST_TIMEOUT).

-spec wait_for_pid_refs(kz_term:pid_refs(), timeout()) -> 'ok'.
wait_for_pid_refs([], _Timeout) -> 'ok';
wait_for_pid_refs(_PidRefs, Timeout) when Timeout < 0 -> 'ok';
wait_for_pid_refs(PidRefs, Timeout) ->
    Start = kz_time:start_time(),
    receive
        {'DOWN', Ref, 'process', Pid, _Reason} ->
            case lists:keytake(Pid, 1, PidRefs) of
                'false' -> wait_for_pid_refs(PidRefs, kz_time:decr_timeout(Timeout, Start));
                {'value', {Pid, Ref}, NewPidRefs} ->
                    wait_for_pid_refs(NewPidRefs, kz_time:decr_timeout(Timeout, Start))
            end
    after Timeout ->
            lager:info("timed out waiting for pid refs: ~p", [PidRefs])
    end.

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
            maybe_capture_ip(Collector, ResolveMe, Resource, ACLBuilderFun, Port);
        'false' ->
            case kz_network_utils:resolve(Host, ecallmgr_util:get_resolve_options()) of
                [] ->
                    lager:debug("no IPs returned, checking for raw IP"),
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
            handle_resource_results(Collector, ViewResources)
    end.

-spec handle_resource_results(pid(), kz_json:objects()) -> 'ok'.
handle_resource_results(Collector, ViewResources) ->
    _ = [handle_resource_result(Collector, ViewResource) || ViewResource <- ViewResources],
    'ok'.

-spec handle_resource_result(pid(), kz_json:object()) -> 'ok'.
handle_resource_result(Collector, ViewResource) ->
    Resource = kz_json:get_json_value(<<"doc">>, ViewResource),

    InboundPidRefs = resource_inbound_ips(Collector, Resource),
    ServerPidRefs = resource_server_ips(Collector, Resource),
    wait_for_pid_refs(InboundPidRefs ++ ServerPidRefs).

%% IPs could be [IP] | [{IP, Port}]
-spec handle_resource_result(pid(), kzd_resources:doc(), kz_term:ne_binaries() | kz_term:proplist()) -> 'ok'.
handle_resource_result(Collector, Resource, IPs) ->
    AuthorizingId = kz_doc:id(Resource),
    {'ok', Master} = kapps_util:get_master_account_id(),
    AccountId = kz_doc:account_id(Resource, Master),
    add_trusted_objects(Collector, AccountId, AuthorizingId, <<"resource">>, IPs).

-spec resource_inbound_ips(pid(), kzd_resources:doc()) -> kz_term:pid_refs().
resource_inbound_ips(Collector, Resource) ->
    [kz_process:spawn_monitor(fun resolve_hostname/4, [Collector
                                                      ,{IP, 'undefined'}
                                                      ,Resource
                                                      ,fun handle_resource_result/3
                                                      ])
     || IP <- kz_json:get_list_value(<<"inbound_ips">>, Resource, [])
    ].

-spec resource_server_ips(pid(), kzd_resources:doc()) -> kz_term:pid_refs().
resource_server_ips(Collector, Resource) ->
    [kz_process:spawn_monitor(fun resolve_hostname/4, [Collector
                                                      ,{kz_json:get_ne_binary_value(<<"server">>, Gateway)
                                                       ,kz_json:get_integer_value(<<"port">>, Gateway)
                                                       }
                                                      ,Resource
                                                      ,fun handle_resource_result/3
                                                      ])
     || Gateway <- kzd_resources:gateways(Resource, []),
        kz_json:get_ne_binary_value(<<"endpoint_type">>, Gateway) =:= <<"sip">>,
        kz_json:is_true(<<"enabled">>, Gateway, 'false')
    ].

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
