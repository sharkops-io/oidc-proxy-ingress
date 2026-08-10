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
    url: registry.gitlab.com/sharkops/helm-charts/oidc-proxy-ingress
    oci: true

releases:
  - name: hubble-auth
    namespace: kube-system
    chart: sharkops-oidc-proxy/oidc-proxy-ingress
    version: 0.1.0
    values:
      - hubble-ingress-values.yaml
```

## The namespace rule

A Kubernetes Ingress backend Service **must be in the Ingress's own
namespace**. The proxy Deployment and Service are therefore always rendered
into the release namespace — so set the release namespace to wherever you
want the Ingress and its TLS secret to live. Only the `upstream` is
cross-namespace, reached by FQDN from inside the proxy pod.

## Credentials

Each release needs a Secret in its namespace with two keys:

| Key | Value |
|---|---|
| `client-secret` | The OIDC client secret |
| `cookie-secret` | 32 random bytes, base64url |

The key names match the `sharkops-universal` oauth2-proxy sidecar, so one
OpenBao path can serve both. Deliver it with an `ExternalSecret`; do not
commit it.

```bash
python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"
```

## Values

| Key | Default | Notes |
|---|---|---|
| `ingressClassName` | `cilium` | |
| `certIssuer` | `letsencrypt-prod` | |
| `issuerUrl` | `https://auth.example.com` | The only line that changes when the IdP changes |
| `clientId` | `oauth2-proxy` | One client can serve every host |
| `cookieDomain` | `.example.com` | Shared so one login covers all protected hosts |
| `existingSecret` | `oauth2-proxy-credentials` | Must exist in the release namespace |
| `image.tag` | `v7.9.0` | |
| `resources` | 10m/32Mi request, 128Mi limit | No CPU limit by design |
| `ingresses` | `[]` | `name`, `host`, `tlsSecret`, `upstream`, `annotations` |

`redirect-url` is not configurable — it is always
`https://<host>/oauth2/callback`, derived from the entry's host. Register
that URL on the OIDC client for every protected host.

## Per-entry annotation overrides

An entry's `annotations` field is merged with the chart-level defaults
(specifically the `certIssuer` value, which becomes `cert-manager.io/cluster-issuer`).
Per-entry annotations take precedence, so you can override the cert issuer for
a single host by including `cert-manager.io/cluster-issuer` in that entry's
`annotations`.

## Tests

```bash
helm unittest --strict -f "tests/*.yaml" .
```
