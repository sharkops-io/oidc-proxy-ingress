# oidc-proxy-ingress

Protects an in-cluster service behind oauth2-proxy and an Ingress, against
any OIDC issuer.

Each entry under `ingresses:` renders three objects — an oauth2-proxy
`Deployment`, its `Service`, and an `Ingress` whose backend is that Service.
oauth2-proxy authenticates the browser and forwards to the real upstream.

## Why this exists

Cilium's Ingress controller supports no forward-auth annotation — GEP-1494
ExternalAuth is unimplemented (cilium#45704) and cilium#23797 is still an
open CFP. So the nginx `auth-url` pattern is unavailable, and protection has
to happen in the request path rather than as an ingress filter.

The predecessor chart, `authentik-proxy-ingress`, solved this by pointing the
whole host at Authentik's embedded outpost. That works but ties every
protected service to Authentik. This chart puts a small oauth2-proxy in front
of each service instead, so the issuer is just a value.

## Usage

```yaml
# helmfile.yaml
repositories:
  - name: sharkops-oidc-proxy
    url: ghcr.io/sharkops-io/charts
    oci: true

releases:
  - name: hubble-auth
    namespace: kube-system
    chart: sharkops-oidc-proxy/oidc-proxy-ingress
    version: 0.5.0
    values:
      - hubble-ingress-values.yaml
```

```yaml
# hubble-ingress-values.yaml
issuerUrl: https://auth.example.com   # required
whitelistDomain: .example.com          # so post-login redirects across hosts work

ingresses:
  - name: hubble-ui
    host: hubble.example.com
    tlsSecret: hubble-tls
    upstream: http://hubble-ui.kube-system.svc.cluster.local:80
```

## The namespace rule

A Kubernetes Ingress backend Service **must be in the Ingress's own
namespace**. The proxy Deployment and Service are therefore always rendered
into the release namespace — so set the release namespace to wherever you
want the Ingress and its TLS secret to live. Only the `upstream` is
cross-namespace, reached by FQDN from inside the proxy pod.

## NetworkPolicy prerequisite

Every rendered pod carries a fixed `app.kubernetes.io/component: oauth2-proxy`
label (not configurable — its value is its stability). If the upstream you're
protecting sits behind a NetworkPolicy, that policy needs a `from` clause
admitting this chart's pods before you migrate the host to it, or the upstream
will start 502ing the moment traffic starts flowing through the proxy instead
of the previous path. Concretely, add an ingress rule like:

```yaml
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: <release-namespace>
      podSelector:
        matchLabels:
          app.kubernetes.io/component: oauth2-proxy
```

A policy written for a previous auth path (for example one that only admits
Authentik's outpost pods) will not admit this chart's pods until you add that
rule. An upstream with no NetworkPolicy needs no change. Editing those policies
is outside this chart; it only gives them something stable to select on.

## Authorization

`--email-domain=*` is hardcoded, with no group restriction by default. That
means: **absent `allowedGroups`, any identity the OIDC issuer authenticates
is admitted**, and the IdP's application policy (who is allowed to reach this
client at all) is the *only* gate. This differs from the predecessor chart,
which could bind a distinct authorization policy per host inside Authentik;
this chart uses one shared `clientId` for every protected host, so the IdP
makes one all-or-nothing decision unless you set `allowedGroups`.

Set `allowedGroups` (chart-wide, per entry, or both) to add a real gate:

```yaml
allowedGroups:        # chart-wide default, applies to every entry below
  - platform-admins

ingresses:
  - name: hubble-ui
    host: hubble.example.com
    tlsSecret: hubble-tls
    upstream: http://hubble-ui.kube-system.svc.cluster.local:80
    allowedGroups:     # overrides the chart-wide list for this entry only
      - observability-team
```

An entry with no `allowedGroups` key falls back to the chart-wide value; an
entry that sets `allowedGroups` (even to `[]`) uses its own list instead. Each
group renders as one `--allowed-group=<group>` argument; the flag is omitted
entirely when the effective list is empty, so a chart with no `allowedGroups`
set anywhere behaves exactly as before this was added.

## Credentials

Each release needs a Secret in its namespace with two keys:

| Key | Value |
|---|---|
| `client-secret` | The OIDC client secret |
| `cookie-secret` | 32 random bytes, base64url |

The key names match the `sharkops-universal` oauth2-proxy sidecar, so one
secret-store path can serve both. Deliver it with an `ExternalSecret`; do not
commit it.

```bash
python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"
```

**When `cookieDomain` is set, `cookie-secret` must be byte-identical in every
namespace where this chart is released.** With `cookieDomain: .example.com`, a
cookie minted by one proxy is presented to all the others sharing that
domain. If a namespace's `cookie-secret` doesn't match, that proxy can't
decrypt cookies minted elsewhere and rejects them — which shows up as an infinite login redirect
loop, not a clear auth error. This is the hardest oauth2-proxy symptom to
diagnose from the outside; if you hit it, checking `cookie-secret` parity
across every release's Secret is the first thing to try.

### Rotating credentials

Credentials arrive via `secretKeyRef`, so Kubernetes won't restart the proxy
pods on its own when an external process rotates the Secret's contents — the
pods keep running with the stale value until something restarts them. The
Deployment carries `deploymentAnnotations` (default:
`reloader.stakater.com/auto: "true"`) for this reason: if
[Reloader](https://github.com/stakater/Reloader) is installed in the cluster,
it watches the Deployment's annotations and restarts the pods when the
referenced Secret changes. If Reloader is *not* installed, this annotation is
inert — rotation still requires a manual restart.

## Values

| Key | Default | Notes |
|---|---|---|
| `ingressClassName` | `cilium` | |
| `certIssuer` | `letsencrypt-prod` | |
| `issuerUrl` | `""` | **Required** (e.g. `https://auth.example.com`); rendering fails without it. The only line that changes when the IdP changes |
| `clientId` | `oauth2-proxy` | One client can serve every host |
| `cookieDomain` | `""` | Empty omits the flag and scopes the cookie per host; set a parent domain (e.g. `.example.com`) for one shared login. See [Cookie scope](#cookie-scope) |
| `whitelistDomain` | `""` | Post-login redirect whitelist. Set it to your parent domain (e.g. `.example.com`) so post-login redirects across hosts work; empty omits the flag. Separate from `cookieDomain` on purpose |
| `existingSecret` | `oauth2-proxy-credentials` | Must exist in the release namespace |
| `cookieName` | `_oauth2_proxy` | Must differ between fleets on different issuers sharing a cookie domain. See [Running two fleets](#running-two-fleets) |
| `allowUnverifiedEmail` | `false` | **Must be `true` against Authentik.** See [Unverified email](#unverified-email) |
| `allowedGroups` | `[]` | See [Authorization](#authorization). Overridable per entry |
| `replicas` | `1` | Overridable per entry |
| `deploymentAnnotations` | `reloader.stakater.com/auto: "true"` | Applied to the Deployment's `metadata.annotations`, not the pod template |
| `podSecurityContext` | `runAsNonRoot: true`, `seccompProfile.type: RuntimeDefault` | |
| `securityContext` | `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true` | Container-level; verified against `quay.io/oauth2-proxy/oauth2-proxy:v7.9.0` |
| `image.tag` | `v7.9.0` | |
| `resources` | 10m/32Mi request, 128Mi limit | No CPU limit by design |
| `ingresses` | `[]` | `name`, `host`, `tlsSecret`, `upstream` are **required** per entry (no safe default exists for any of them); `replicas`, `allowedGroups`, `annotations` are optional overrides |

`redirect-url` is not configurable — it is always
`https://<host>/oauth2/callback`, derived from the entry's host. Register
that URL on the OIDC client for every protected host.

## Cookie scope

A `cookieDomain` set to a parent domain gives you one login across every host
under it. The cost is that the browser sends that cookie to **every** host in
the domain, including services that have nothing to do with authentication.

That cost is not theoretical. Two fleets' cookies together overran the
4096-byte default header buffer of an unrelated Fiber/fasthttp app in the same
domain, which then returned **431 Request Header Fields Too Large** to every
request. It had never been touched — it simply shared a parent domain with the
proxies. The problem grows with each protected host and is paid by services that
get no benefit.

Leave `cookieDomain` empty to omit the flag; oauth2-proxy then scopes each
cookie to its own host. SSO still works, because the IdP keeps its own session —
the extra hop is a silent redirect, not a second login.

Set `whitelistDomain` to the parent domain either way. It governs where
oauth2-proxy will redirect after login, and collapsing it with `cookieDomain`
would start rejecting valid post-login redirects.

## Running two fleets

During an IdP migration you may want one host on the new issuer while the rest
stay on the old one. `issuerUrl` and `clientId` are chart-wide, so that means a
second release — and the second release needs **both** of these, or it will
appear to work while proving nothing:

- **Its own `cookieName`.** All instances default to `_oauth2_proxy`, and a
  browser keeps one cookie of a given name per domain, so two fleets on one
  `cookieDomain` overwrite each other's sessions.
- **Its own `existingSecret`**, holding a different `cookie-secret`. Cookie
  validity is decided by decryption, not by issuer: with a shared secret, a
  proxy pointed at the new IdP will accept a session minted against the old one
  and never redirect for a login at all.

Verify isolation explicitly — log into a host on one fleet, then load a host on
the other and confirm it still demands a login.

## Unverified email

If login succeeds and then `/oauth2/callback` returns **500**, check the proxy
log for:

```
Error redeeming code during OAuth2 callback: email in id_token (...) isn't verified
```

The token exchange worked; oauth2-proxy rejected the resulting id_token because
its `email_verified` claim is false. Authentik's default *OpenID 'email'* scope
mapping hardcodes exactly that:

```python
return {
    "email": request.user.email,
    "email_verified": False
}
```

It has no email-verification flow, so it will not claim otherwise. Set
`allowUnverifiedEmail: true`.

Despite the flag's name this is not a meaningful weakening **here**: with
`--email-domain=*` the email claim is not an authorization input, so trust rests
on the issuer having authenticated the user. It would matter if you granted
access by email address or domain, where an unverified address becomes an
impersonation vector. Hence opt-in, and off by default.

That reasoning does not depend on network position. Do not treat a LAN-only
deployment as the justification - a chart used on an internet-facing host would
be equally safe under `--email-domain=*` and equally unsafe if it gated on the
address.

The alternative - a custom scope mapping asserting `email_verified: True` - makes
Authentik state something it has not checked. Prefer the flag.

## Per-entry annotation overrides

An entry's `annotations` field is merged with the chart-level defaults
(specifically the `certIssuer` value, which becomes `cert-manager.io/cluster-issuer`).
Per-entry annotations take precedence, so you can override the cert issuer for
a single host by including `cert-manager.io/cluster-issuer` in that entry's
`annotations`. Every annotation value is rendered as a quoted string
regardless of how it's written in YAML, so `gethomepage.dev/enabled: true`
(unquoted) and `gethomepage.dev/enabled: "true"` (quoted) render identically —
the API server always sees a string, never a native boolean.

## Migrating from authentik-proxy-ingress

To move an `authentik-proxy-ingress` release to this chart **in place**,
keeping the existing TLS Secret and cert-manager `Certificate` untouched (the
examples below assume the predecessor lives in namespace `authentik`):

1. Keep the release in the **same namespace** (`authentik`) and give it the
   **same release name** as the `authentik-proxy-ingress` release it
   replaces.
2. Keep the entry's `name:` **unchanged** — that's what determines the
   rendered Ingress object's name, and an unchanged name lets Helm adopt the
   existing Ingress in place rather than create a second one.
3. Add `upstream:` (the predecessor didn't need it — it pointed the whole
   host at Authentik's outpost instead of a per-host proxy).
4. Swap the `chart:` reference from `authentik-proxy-ingress` to
   `oidc-proxy-ingress`.

Do **not** move the release to a different namespace as part of the
migration. Nothing about the Ingress or Service *requires* namespace
`authentik` specifically (see [The namespace
rule](#the-namespace-rule)) — but changing the namespace changes the
Ingress object's identity from Helm's point of view, which means two
Ingresses briefly claim the same host during cutover (undefined behavior
under Cilium) and a re-issued TLS certificate. Keeping namespace, release
name and entry `name` all unchanged is what makes this an in-place upgrade
instead of a cutover.

Before migrating a host that sits behind a NetworkPolicy, see [NetworkPolicy
prerequisite](#networkpolicy-prerequisite) first.

## Tests

```bash
helm unittest --strict -f "tests/*.yaml" .
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
