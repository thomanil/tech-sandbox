# Custom domain + TLS on the UpCloud load balancer

> **TL;DR**
> 1. **DNS** — DNSimple **ALIAS** `tknilsson-sandbox.com` → `lb-…upcloudlb.com` (the LB hostname).
> 2. **Cert** — create an UpCloud **dynamic** certificate bundle for the domain (auto-issued + auto-renewed, ZeroSSL DV). Copy its UUID.
> 3. **Attach by UUID in the annotation** — put `certificate_bundle_uuid` in the `443` frontend's `tls_configs` in `k8s/timeline-server-upcloud.yaml`, then `./scripts/deploy-upcloud.sh`. **Never attach in the Hub** — the CCM overwrites manual attaches on *every* reconcile (verified: stripped in ~12s).
> 4. **Verify** — `openssl s_client -connect tknilsson-sandbox.com:443 -servername tknilsson-sandbox.com </dev/null 2>/dev/null | openssl x509 -noout -subject` → `CN=tknilsson-sandbox.com`.
> 5. **On LB/cluster recreate** — the bundle UUID is new: re-point the ALIAS, recreate the bundle, update the UUID in the manifest, redeploy. That one-line UUID edit is the only recurring touch.
>
> Current bundle UUID: `0a1fe407-5173-4754-892b-afa6386c5a7f` (DNSimple-issued Let's Encrypt certs are **not** used by this setup).

How to serve the timeline server on a custom domain over HTTPS/WSS, with a cert
that **survives Kubernetes CCM reconciliation**. The cert is an UpCloud-issued
**dynamic** bundle (auto-issued, auto-renewed by UpCloud — ZeroSSL DV), and it's
attached to the frontend **declaratively via the Service annotation**, not by
clicking in the Hub.

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
frontend** with the **same cert** — a cert is per-hostname, not per-protocol, so
once it covers the domain, both work. No protocol-specific config.

> DNSimple's only job here is **one ALIAS record** (apex → LB hostname). UpCloud
> issues the cert. A Let's Encrypt cert *ordered in DNSimple is not used* by this
> setup — DNSimple only issues, it never terminates TLS.

---

## The rule that governs everything: the CCM overwrites manual changes

This load balancer is **provisioned and managed by the Kubernetes Cloud
Controller Manager (CCM)** — it exists because of the
`service.beta.kubernetes.io/upcloud-load-balancer-config` annotation on the
Service. From the UpCloud CCM docs:

> if your Managed Load Balancer is managed by the UKS cluster, all Load Balancer
> configuration changes should be made through object annotations. **All manual
> modifications done to the Load Balancer through Hub or API are overwritten.**

**This was verified empirically** (see Appendix): attaching the cert by hand in
the Hub works *until the next reconcile*, then it's stripped. A reconcile is
triggered by **any** Service update — every `deploy-upcloud.sh`, every rollout,
periodic resync. In the test, a single throwaway annotation reverted the served
cert from `tknilsson-sandbox.com` to the `upcloudlb.com` host within ~12 seconds.

**Conclusion: never attach the domain cert by hand. Reference it in the
annotation by UUID** so the CCM keeps it attached.

---

## Prerequisites

- DNS resolves the domain to the LB:

  ```bash
  dig +short tknilsson-sandbox.com          # must return 212.147.232.159 (the LB)
  ```

  Apex → DNSimple **ALIAS** record → the LB hostname. Subdomain → **CNAME**.

- Cluster reachable via the pinned kubeconfig (deploy script enforces context
  `kubernetes-admin@tech-sandbox-upcloud-k8s-cluster`).

- Access to the UpCloud **Hub** (https://hub.upcloud.com) to create the dynamic
  bundle once and read its UUID.

---

## Step 1 — Create the dynamic certificate bundle for the domain (one time)

The bundle is an UpCloud resource that *persists* across reconciles (only its
*attachment* to the frontend is what the CCM manages). Create it once:

1. Hub → your Load Balancer → Frontends → **Certificates**.
2. Create a **Dynamic** certificate; set its domain/hostname to
   **`tknilsson-sandbox.com`** (add `www.tknilsson-sandbox.com` too if you want
   www — see "Adding www"). Key type ECDSA is fine.
3. Because DNS already points the domain at the LB, UpCloud validates ownership
   and issues the cert (ZeroSSL DV), and will **auto-renew** it.
4. **Copy the bundle's UUID** (e.g. `0aded5c1-c7a3-498a-b9c8-a871611c47a2`).

> Do **not** bother attaching it to the frontend here — that attachment would be
> wiped on the next reconcile. The annotation (Step 2) does the durable attach.

## Step 2 — Reference the bundle by UUID in the annotation

Edit the Service annotation in `k8s/timeline-server-upcloud.yaml` to attach the
bundle declaratively:

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
              { "name": "tknilsson-sandbox", "certificate_bundle_uuid": "<UUID-from-step-1>" }
            ]
          }
        ]
      }
```

Notes:

- `mode` **must stay `http`** (not `tcp`) — `http` mode terminates TLS at the LB
  *and* carries the WebSocket `Upgrade` so `wss://…/ws` works.
- This replaces the earlier `{ "name": "needs-certificate" }` trigger.
  `needs-certificate` only ever covers the LB's own `*.upcloudlb.com` hostname and
  has **no field for a custom domain** — that's why we reference the domain bundle
  by UUID instead. (You can keep a second `needs-certificate` entry alongside it
  if you also want the LB-hostname cert; not required.)
- Leave `spec.ports` (80→8000 and 443→8000) unchanged.

## Step 3 — Deploy

```bash
./scripts/deploy-upcloud.sh
```

The CCM applies the annotation and attaches the bundle to the 443 frontend.

## Step 4 — Verify, then prove it's durable

```bash
# Served cert should be FOR your domain:
echo | openssl s_client -connect tknilsson-sandbox.com:443 \
  -servername tknilsson-sandbox.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName

curl -fsS https://tknilsson-sandbox.com/healthz && echo OK
```

Expect `subject=CN=tknilsson-sandbox.com` and a SAN listing your domain.

**Prove durability** (the whole point) by forcing a reconcile and re-checking —
unlike the manual attach, this should now survive:

```bash
KC="$HOME/.secrets/tech-sandbox-upcloud-k8s-cluster_kubeconfig.yaml"
KUBECONFIG="$KC" kubectl annotate svc timeline-server reconcile-test=1 --overwrite
sleep 20
echo | openssl s_client -connect tknilsson-sandbox.com:443 -servername tknilsson-sandbox.com 2>/dev/null \
  | openssl x509 -noout -subject            # should STILL be CN=tknilsson-sandbox.com
KUBECONFIG="$KC" kubectl annotate svc timeline-server reconcile-test-   # cleanup
```

Then update the client server lists (kept in sync per `CLAUDE.md`):

- `app/client-python-qt/timeline_client.py` → `SERVERS`
- `app/client-web/src/lib/servers.ts` → `SERVERS`

…both pointing at `wss://tknilsson-sandbox.com/ws`.

---

## Adding `www` (optional)

1. DNSimple → add a **CNAME**: `www` → `lb-0a473f0a3c4c4d3ba2adf3e8c27c2470-1.upcloudlb.com`.
2. Add `www.tknilsson-sandbox.com` to the same dynamic bundle (Step 1).
3. Re-verify with `-servername www.tknilsson-sandbox.com`.

## Renewal

Nothing to do — UpCloud auto-renews the dynamic bundle. The UUID is stable across
renewals, so the annotation doesn't change.

---

## On cluster / load balancer **recreate**

A recreated LB is a new resource, so the dynamic bundle (and its UUID) is new.
The recurring steps are:

1. **DNS:** update the DNSimple **ALIAS** record to the *new* LB hostname.
2. **Bundle:** create the dynamic bundle for `tknilsson-sandbox.com` on the new
   LB (Step 1) and copy the **new UUID**.
3. **Annotation:** update `certificate_bundle_uuid` in
   `k8s/timeline-server-upcloud.yaml` to the new UUID, then `deploy-upcloud.sh`.

This is the *only* recurring manual touch, and it's a one-line manifest edit
committed to git — not Hub clicking. Routine updates/deploys in between need
nothing, because the cert is declared in the annotation.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `openssl` shows `CN=lb-…upcloudlb.com`; browser "not secure" | Domain bundle not attached via annotation (or wrong/missing UUID) | Put the correct `certificate_bundle_uuid` in the annotation (Step 2), deploy |
| Cert worked, then vanished after a deploy | You attached it **manually** in the Hub; CCM overwrote it | Use the UUID-in-annotation method instead of manual attach |
| `dig` ≠ `212.147.232.159` | DNS not pointed / not propagated | Fix the DNSimple ALIAS; wait for TTL |
| Dynamic bundle stuck "pending"/failed | ACME couldn't validate | Ensure DNS resolves to the LB and the LB is publicly reachable on 443 before/while issuing |
| WSS connects then drops when idle | LB idle timeout closes quiet WS | Raise LB frontend/backend timeout, or add app-level ping/pong (server pushes only on change, so a paused client is silent) |

---

## Appendix: the reconcile experiment (2026-06)

Done to confirm the CCM overwrite behavior:

1. Baseline: served cert was `CN=tknilsson-sandbox.com` (manually attached in Hub);
   deployed annotation only declared `{ "name": "needs-certificate" }`.
2. Forced a reconcile with a throwaway annotation:
   `kubectl annotate svc timeline-server ccm-reconcile-test=1 --overwrite`.
3. Within ~12 s the served cert reverted to
   `CN=lb-0a473f0a3c4c4d3ba2adf3e8c27c2470-1.upcloudlb.com` and stayed there.

→ Manual Hub attachments do not survive reconciliation. The UUID-in-annotation
method (above) is the durable fix.

---

## Alternative: manual (non-dynamic) bundle from a DNSimple cert

Only if you must use a cert issued by DNSimple rather than UpCloud: download
cert + chain + key from DNSimple, create a **Manual** bundle in UpCloud, and
reference it the same way — by UUID — in the annotation. Downside: **re-upload on
every ~90-day renewal** (dynamic bundles avoid this). The annotation shape is
identical; only the bundle type and renewal burden differ.
