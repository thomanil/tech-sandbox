# Custom domain + TLS on the UpCloud load balancer (dynamic bundle)

How to serve the timeline server on a custom domain over HTTPS/WSS, using an
**UpCloud-issued dynamic certificate** (auto-issued, auto-renewed). This is the
low-maintenance path: UpCloud issues *and* terminates *and* renews the cert —
you never download, upload, or rotate anything.

Worked example uses the real values for this project:

| Thing            | Value                                                        |
| ---------------- | ------------------------------------------------------------ |
| Domain           | `tknilsson-sandbox.com`                                       |
| DNS host         | DNSimple                                                      |
| LB hostname      | `lb-0a473f0a3c4c4d3ba2adf3e8c27c2470-1.upcloudlb.com`         |
| LB public IP     | `212.147.232.159`                                             |
| Manifest         | `k8s/timeline-server-upcloud.yaml`                           |
| Deploy           | `scripts/deploy-upcloud.sh`                                  |

Both `https://tknilsson-sandbox.com` (web client) and
`wss://tknilsson-sandbox.com/ws` (WebSocket) ride the **same 443 `http`-mode
frontend** with the **same cert** — there is no protocol-specific work. A cert
is per-hostname, not per-protocol, so once the cert covers the domain, both go
green at once.

---

## The one thing that's easy to get wrong

This load balancer is **provisioned and managed by the Kubernetes Cloud
Controller Manager (CCM)** — it exists because of the
`service.beta.kubernetes.io/upcloud-load-balancer-config` annotation on the
Service. Two consequences:

1. **Drive LB config through the Service annotation, not the Hub UI.** The CCM
   reconciles the LB back to the manifest; settings you click in manually can be
   reverted.
2. **Except the cert's domain list.** There is *no* annotation field to say
   which domains the dynamic cert should cover (the annotation only has the
   `needs-certificate` trigger — one auto-TLS per LB). The domain is attached to
   the dynamic **certificate bundle** itself, via the UpCloud Hub or API, *after*
   DNS points at the LB. That bundle's domain list is the one piece you manage
   outside the manifest.

So the flow is: **annotation creates the dynamic bundle → you add your domain to
that bundle → UpCloud validates (DNS already points at the LB) and issues.**

---

## Prerequisites

- DNS for the domain already resolves to the LB. Confirm:

  ```bash
  dig +short tknilsson-sandbox.com          # must return 212.147.232.159 (the LB)
  ```

  For the apex this is a DNSimple **ALIAS** record → the LB hostname. For a
  subdomain (`app.…`) it'd be a **CNAME**. (Already done for the apex.)

- You can reach the UpCloud cluster with the pinned kubeconfig (the deploy script
  enforces context `kubernetes-admin@tech-sandbox-upcloud-k8s-cluster`).

- Access to the UpCloud **Hub** (https://hub.upcloud.com) for the one bundle step.

---

## Step 1 — Put the `needs-certificate` trigger in the manifest

Edit the Service annotation in `k8s/timeline-server-upcloud.yaml` so the 443
frontend explicitly requests auto-TLS. Add the `tls_configs` block:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/upcloud-load-balancer-config: |
      {
        "frontends": [
          {
            "name": "https",
            "mode": "http",
            "port": 443,
            "tls_configs": [
              { "name": "needs-certificate" }
            ]
          }
        ]
      }
```

Notes:

- `mode` **must stay `http`** (not `tcp`). `http` mode is what (a) terminates TLS
  at the LB and (b) carries the WebSocket `Upgrade` so `wss://…/ws` works. `tcp`
  mode would break both for this setup.
- `"name": "needs-certificate"` is the special trigger that makes UpCloud create
  and attach a **dynamic** certificate bundle. (Per the docs, a 443 `http`
  frontend with *no* `tls_configs` already auto-triggers this — but stating it
  explicitly is clearer and self-documenting.)
- Leave `spec.ports` (the `http` 80→8000 and `https` 443→8000 mappings)
  unchanged.

## Step 2 — Deploy

```bash
./scripts/deploy-upcloud.sh
```

This applies the manifest and rolls the deployment. The CCM updates the LB and
ensures a dynamic certificate bundle exists. At this point the bundle covers the
LB's own `*.upcloudlb.com` hostname — **not yet your domain**. That's Step 3.

## Step 3 — Add your domain to the dynamic certificate bundle (Hub or API)

This is the step that isn't in the manifest.

### Option A — UpCloud Hub (click-path)

1. Hub → **Networking → Load Balancers** → select this load balancer.
2. Open **Certificate bundles** (a.k.a. SSL certificates) and find the **dynamic**
   bundle the CCM created.
3. Add **`tknilsson-sandbox.com`** to the bundle's domain / hostname list (add
   `www.tknilsson-sandbox.com` too if you want www — see "Adding www" below).
4. Save. UpCloud runs the ACME validation. Because DNS already resolves the
   domain to the LB, the HTTP/TLS-ALPN challenge is answered at the LB and the
   cert issues — typically within a minute or two.

### Option B — UpCloud API (scriptable)

The bundle's domains are also settable via the Managed Load Balancer API
(`/1.3/load-balancer/.../certificate-bundles`, dynamic bundle has a `hostnames`
list). Use this if you want the domain list in version control / automation.
Reference: https://developers.upcloud.com/ (Managed Load Balancer →
certificate bundles).

> ⚠️ Verify Hub-added domains survive CCM reconciliation. The CCM owns the LB; in
> practice the dynamic bundle's domain list is managed on the bundle (not the
> annotation) and persists, but after your next `deploy-upcloud.sh` re-check
> Step 5 to be sure the domain is still on the cert.

## Step 4 — Wait for issuance

Give it 1–3 minutes after adding the domain. The Hub shows the bundle status;
issuance flips it to active once the cert covering your domain is live.

## Step 5 — Verify

```bash
# The served cert should now be FOR your domain (not the upcloudlb.com host):
echo | openssl s_client -connect tknilsson-sandbox.com:443 \
  -servername tknilsson-sandbox.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName

# App reachable + green over HTTPS and WSS (same 443 frontend):
curl -fsS https://tknilsson-sandbox.com/healthz && echo OK
```

Success looks like:

```
subject=CN=tknilsson-sandbox.com
issuer = ...ZeroSSL...                      # UpCloud's dynamic certs are ZeroSSL DV
X509v3 Subject Alternative Name:
    DNS:tknilsson-sandbox.com               # ← your domain, the whole point
```

If `subject`/SAN still shows `lb-…upcloudlb.com`, the domain hasn't been attached
to the bundle yet (or issuance hasn't completed) — recheck Step 3/4.

Then update the client server lists (kept in sync per `CLAUDE.md`) to the new URL:

- `app/client-python-qt/timeline_client.py` → `SERVERS`
- `app/client-web/src/lib/servers.ts` → `SERVERS`

…both pointing at `wss://tknilsson-sandbox.com/ws`.

---

## Adding `www` (optional)

Only the apex resolves today. To also serve `www`:

1. DNSimple → add a **CNAME** record: `www` → `lb-0a473f0a3c4c4d3ba2adf3e8c27c2470-1.upcloudlb.com`.
2. Add `www.tknilsson-sandbox.com` to the same dynamic bundle (Step 3).
3. Re-verify with `-servername www.tknilsson-sandbox.com` (Step 5).

---

## Renewal

Nothing to do. UpCloud's dynamic bundle **auto-renews** the cert. This is the
main reason to prefer it over a DNSimple-issued cert: a DNSimple cert would have
to be downloaded and re-uploaded to the LB as a *manual* bundle on every ~90-day
renewal. With the dynamic bundle that chore disappears.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Browser "not secure" / name mismatch; `openssl` shows `CN=lb-…upcloudlb.com` | Domain not yet on the bundle | Do Step 3, wait for issuance |
| `dig +short tknilsson-sandbox.com` ≠ `212.147.232.159` | DNS not pointed / not propagated | Fix the DNSimple ALIAS; wait for TTL |
| Issuance stuck / fails | ACME couldn't validate | Confirm DNS resolves to the LB *before* adding the domain; the LB must be publicly reachable on 443 |
| WSS connects then drops when idle | LB idle timeout closes quiet WS | Bump the LB frontend/backend timeout, or add app-level ping/pong keepalive (server pushes only on change, so a paused client is silent) |
| Domain fell off the cert after a deploy | CCM reconciled the LB | Re-add the domain to the bundle (Step 3); report to UpCloud if it recurs |

---

## Rollback

To revert to the no-custom-domain state, remove the `tls_configs` block from the
annotation (or set it back to a bare `{ "name": "https", "mode": "http", "port":
443 }`) and `./scripts/deploy-upcloud.sh`. The LB falls back to its
`*.upcloudlb.com` cert. Removing the domain from the bundle in the Hub is
optional cleanup.

---

## Alternative: manual bundle (only if you must use the DNSimple-issued cert)

If you specifically need the cert to originate from DNSimple instead of UpCloud:
download cert + chain + key from DNSimple, create a **Manual** bundle in UpCloud,
and reference it by UUID in the annotation:

```json
"tls_configs": [
  { "name": "mycert", "certificate_bundle_uuid": "<uuid-of-manual-bundle>" }
]
```

Downside: **you must re-upload on every renewal** (~90 days). The dynamic-bundle
path above avoids this entirely, which is why it's the recommended one.
