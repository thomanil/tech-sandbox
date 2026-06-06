import { useCallback, useEffect, useRef, useState } from 'react'

import { resolveServerUrl } from '@/lib/servers'

/** The single state message the server pushes on connect and every change
 *  (see timeline_server.py `state_message`). `window` entries are ints, or null
 *  for positions before the start of the sequence. */
export type TimelineState = {
  window: (number | null)[]
  sequenceName: string
  sequences: string[]
  playing: boolean
}

/** Connection status, mirroring the Qt client's banner states. */
export type ConnStatus =
  | { kind: 'connecting'; label: string }
  | { kind: 'online' }
  | { kind: 'offline'; label: string; isError: boolean }

const RECONNECT_MS = 2000

/** A new random integer seed per browser session, sent as ?client_id= so the
 *  server keys our timeline on it and resumes it across reconnects / server
 *  switches — exactly like the Qt client's per-process seed. */
function randomSeed(): number {
  return Math.floor(Math.random() * 2_147_483_647) + 1
}

/**
 * Thin WebSocket client for the timeline server — the React analog of the Qt
 * client's QWebSocket wiring. Holds no authoritative state: it renders whatever
 * window the server pushes and sends command messages on user actions. It keeps
 * one socket to `serverLabel`'s URL, auto-reconnects every 2s while down, and
 * tears down + reconnects when the selected server changes.
 */
export function useTimelineSocket(serverLabel: string) {
  const clientId = useRef(randomSeed())
  const wsRef = useRef<WebSocket | null>(null)
  const [state, setState] = useState<TimelineState | null>(null)
  const [status, setStatus] = useState<ConnStatus>({
    kind: 'connecting',
    label: 'Connecting to server…',
  })

  useEffect(() => {
    const url = resolveServerUrl(serverLabel)
    let disposed = false
    let reconnect: ReturnType<typeof setTimeout> | null = null

    const connect = () => {
      if (disposed) return
      setStatus({ kind: 'connecting', label: `Connecting to ${serverLabel}…` })
      // `wasOpen` lets us tell "never reached the server" (error banner) from
      // "an established connection dropped" (lost-connection banner), the way
      // the Qt client splits on_error vs on_disconnected.
      let wasOpen = false
      const ws = new WebSocket(`${url}?client_id=${clientId.current}`)
      wsRef.current = ws

      ws.onopen = () => {
        wasOpen = true
        setStatus({ kind: 'online' })
      }
      ws.onmessage = (event) => {
        const msg = JSON.parse(event.data)
        if (msg.type !== 'state') return
        setState({
          window: msg.window,
          sequenceName: msg.sequence_name,
          sequences: msg.sequences,
          playing: msg.playing,
        })
      }
      ws.onclose = () => {
        // Only retract the shared ref if it still points at THIS socket. On a
        // server switch the previous socket's onclose fires *after* the new
        // socket is already installed; nulling unconditionally would wipe the
        // new socket's ref, leaving send() with nothing to write to — live
        // connection, dead controls, and no error banner.
        if (wsRef.current === ws) wsRef.current = null
        if (disposed) return
        setStatus({
          kind: 'offline',
          isError: true,
          label: wasOpen
            ? 'Lost connection to server. Reconnecting…'
            : `Cannot reach ${serverLabel}. Is the timeline server running? Retrying…`,
        })
        reconnect = setTimeout(connect, RECONNECT_MS)
      }
      // onerror always precedes onclose in browsers; let onclose own the banner.
    }

    // Defer the first connect to a microtask so the initial setStatus runs in a
    // callback rather than synchronously in the effect body (cleaner re-renders;
    // satisfies react-hooks/set-state-in-effect). Imperceptible delay.
    queueMicrotask(connect)

    return () => {
      disposed = true
      if (reconnect) clearTimeout(reconnect)
      wsRef.current?.close()
      wsRef.current = null
    }
  }, [serverLabel])

  const send = useCallback((action: string, extra?: Record<string, unknown>) => {
    const ws = wsRef.current
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'command', action, ...extra }))
    }
  }, [])

  return { state, status, connected: status.kind === 'online', send }
}
