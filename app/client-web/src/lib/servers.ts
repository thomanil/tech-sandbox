// Backend environments the web client can talk to, mirroring the Qt client's
// SERVERS map (app/client-python-qt/timeline_client.py).
//
// The web client has a mode the Qt client doesn't: in the shipped build it is
// *served by* the backend, so it just talks to that same origin (derive
// ws://host/ws from window.location — works unchanged on the baked image, the
// minikube NodePort, and the UpCloud LB). That "same origin" entry is therefore
// the production default, and the Server picker is hidden there (see
// TimelinePlayer) — it's the one environment you can't be in any other.
//
// In local dev the page is the Vite dev server, a separate origin, so "same
// origin" doesn't apply; the picker is shown and offers the explicit backends
// below (defaulting to the Local docker one you run alongside Vite).

export const SAME_ORIGIN_LABEL = 'Same origin (served)'

// `null` means "derive from window.location" (see resolveServerUrl).
export const SERVERS: Record<string, string | null> = {
  [SAME_ORIGIN_LABEL]: null,
  'Local docker (start-server.sh)': 'ws://127.0.0.1:8000/ws',
  // NodePort on the minikube cluster; the IP is minikube's own (stable on the
  // docker driver). Update it if you recreate the cluster.
  'Local minikube (deploy-minikube.sh)': 'ws://192.168.49.2:30080/ws',
  // TLS-terminated at the UpCloud LB's 443 frontend, so wss:// on the default port.
  'Remote UpCloud': 'wss://lb-0acd94799dc24f208d245ba808d7fdbe-1.upcloudlb.com/ws',
}

// Shipped build → the serving origin; local dev → the Local docker backend.
// import.meta.env.DEV is statically true under the Vite dev server, false in
// `vite build`, so this constant-folds per build.
export const DEFAULT_SERVER = import.meta.env.DEV ? 'Local docker' : SAME_ORIGIN_LABEL

/** The ws:// (or wss://) URL for a server label, deriving the same-origin one
 *  from the current page so it follows http→ws / https→wss automatically. */
export function resolveServerUrl(label: string): string {
  const configured = SERVERS[label]
  if (configured) return configured
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${proto}//${window.location.host}/ws`
}
