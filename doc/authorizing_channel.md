# Authorizing a Channel

eCallMgr may perform channel authorization if it is using resource.

If a channel is using a global resource `Global-Resource: true` is set on its CCVs. If it is global authz will be
performed.

When not using a global resource, and there is `Resource-Id` is set (for outbound direction) or if there is no
`Authorizing-ID` or else `Authorizing-Type` is `resource`, then this channel is considered using a local resource and
maybe be not authz if configured as such.

There are few ways to configure if

- The legacy `authz_local_resource` will use as fallback and figure outing the default modules to skip authz.
- If `Authz-Number-Module` has in CCVs, it compares to list of `skip_authz_modules` (default to `[knm_local]`), to
  either skip authz or perform it.
