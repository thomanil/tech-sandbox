import { useState } from 'react'
import {
  PlayIcon,
  SquareIcon,
  SkipBackIcon,
  SkipForwardIcon,
  WifiOffIcon,
} from 'lucide-react'

import { DEFAULT_SERVER, SAME_ORIGIN_LABEL, SERVERS } from '@/lib/servers'
import { useTimelineSocket } from '@/hooks/useTimelineSocket'
import { TimelineWindow } from '@/components/TimelineWindow'
import { Alert, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardAction,
  CardContent,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'

/**
 * The timeline web client — a port of the Qt client (timeline_client.py) onto
 * shadcn/ui. A thin renderer over useTimelineSocket: it draws the server-pushed
 * window, exposes the sequence + server pickers and the transport controls, and
 * shows a status banner (disabling controls) whenever it isn't connected.
 */
export function TimelinePlayer() {
  // Which backend we talk to; switching it re-points the socket (see the hook).
  const [server, setServer] = useState(DEFAULT_SERVER)
  const { state, status, connected, send } = useTimelineSocket(server)

  // The Server picker only makes sense in local dev, where the Vite dev server
  // is a separate origin and you may want to aim it at different backends. When
  // the app is served *out of* a backend container (the production `vite build`,
  // import.meta.env.DEV === false), the backend is fixed to that same origin —
  // which is exactly the default — so the picker is hidden as meaningless. And
  // because the picker is dev-only, it never offers "same origin (served)": that
  // label describes the container-served mode you can't be in during dev.
  const showServerPicker = import.meta.env.DEV

  return (
    <Card className="w-full max-w-xl gap-0">
      <CardHeader className="border-b">
        <CardTitle className="text-lg">Timeline</CardTitle>
        <span className="text-gray-500">Streaming number sequence state, state driven over websocket from a python api server</span>
        <CardAction className="self-center">
          {connected ? (
            <Badge variant={state?.playing ? 'default' : 'secondary'}>
              {state?.playing ? 'Playing' : 'Paused'}
            </Badge>
          ) : (
            <Badge variant="outline" className="text-muted-foreground">
              <WifiOffIcon className="size-3" />
              Offline
            </Badge>
          )}
        </CardAction>
      </CardHeader>

      <CardContent className="px-6 py-0">
        {/* Timeline, or the status banner in its place when not connected —
            mirrors the Qt client hiding the timeline behind the banner. */}
        {connected && state ? (
          <TimelineWindow window={state.window} />
        ) : (
          <div className="flex min-h-[152px] items-center justify-center">
            <Alert
              variant={status.kind === 'offline' && status.isError ? 'destructive' : 'default'}
              className="w-auto"
            >
              <AlertTitle>
                {status.kind === 'online' ? 'Waiting for state…' : status.label}
              </AlertTitle>
            </Alert>
          </div>
        )}
      </CardContent>

      <CardFooter className="flex-col gap-4 border-t pt-6">
        {/* Pickers: sequence (server-driven) + backend environment. */}
        <div className="grid w-full max-w-xs grid-cols-[auto_1fr] items-center gap-x-3 gap-y-2">
          <label className="text-right text-sm text-muted-foreground">Sequence</label>
          <Select
            value={state?.sequenceName ?? ''}
            onValueChange={(name) => send('set_sequence', { name })}
            disabled={!connected || !state}
          >
            <SelectTrigger className="w-full">
              <SelectValue placeholder="—" />
            </SelectTrigger>
            <SelectContent>
              {state?.sequences.map((name) => (
                <SelectItem key={name} value={name}>
                  {name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>

          {showServerPicker && (
            <>
              <label className="text-right text-sm text-muted-foreground">Server</label>
              <Select value={server} onValueChange={setServer}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Object.keys(SERVERS)
                    .filter((label) => label !== SAME_ORIGIN_LABEL)
                    .map((label) => (
                      <SelectItem key={label} value={label}>
                        {label}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
            </>
          )}
        </div>

        {/* Transport controls — disabled until connected, like the Qt client. */}
        <div className="flex items-center justify-center gap-2">
          <Button
            variant="outline"
            size="icon"
            aria-label="Step back"
            disabled={!connected}
            onClick={() => send('back')}
          >
            <SkipBackIcon />
          </Button>
          <Button
            variant={state?.playing ? 'outline' : 'default'}
            size="icon"
            aria-label="Play"
            disabled={!connected}
            onClick={() => send('play')}
          >
            <PlayIcon />
          </Button>
          <Button
            variant={state?.playing ? 'default' : 'outline'}
            size="icon"
            aria-label="Stop"
            disabled={!connected}
            onClick={() => send('stop')}
          >
            <SquareIcon />
          </Button>
          <Button
            variant="outline"
            size="icon"
            aria-label="Step forward"
            disabled={!connected}
            onClick={() => send('forward')}
          >
            <SkipForwardIcon />
          </Button>
        </div>
      </CardFooter>
    </Card>
  )
}
