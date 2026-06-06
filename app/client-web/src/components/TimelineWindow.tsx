import { cn } from '@/lib/utils'

/**
 * Renders the server-provided timeline window — the visual port of the Qt
 * client's TimelineWidget. The center value is large, bold, and accented; the
 * neighbours shrink and fade with distance (nearer = darker/more opaque), and
 * null positions (before the start of the sequence) render as empty cells so the
 * row keeps a stable width as the timeline scrolls.
 */
export function TimelineWindow({ window }: { window: (number | null)[] }) {
  const radius = (window.length - 1) / 2
  return (
    <div className="flex items-center justify-center gap-1 py-8 select-none">
      {window.map((n, i) => {
        const offset = i - radius
        const isCenter = offset === 0
        // dist: 0 at the centre, →1 at the window edge.
        const dist = Math.abs(offset) / radius
        // Port of the Qt client's neighbour fade, but cranked across three cues
        // at once so the gradient actually reads: the base colour is already
        // muted (not full foreground), the opacity drops steeply with distance
        // (~0.9 nearest → ~0.1 at the edge), and the font shrinks from ~1.4rem
        // down to ~0.8rem. Opacity-toward-background stays correct in dark mode,
        // where the Qt client's literal grey ramp would brighten instead of fade.
        return (
          <div
            key={i}
            className="flex min-w-[68px] justify-center font-mono tabular-nums"
          >
            {n === null ? null : (
              <span
                className={cn(
                  'transition-all duration-150',
                  isCenter
                    ? 'text-4xl font-bold text-blue-600 dark:text-blue-400'
                    : 'text-muted-foreground',
                )}
                style={
                  isCenter
                    ? undefined
                    : { opacity: 1 - 0.85 * dist, fontSize: `${1.4 - 0.6 * dist}rem` }
                }
              >
                {n}
              </span>
            )}
          </div>
        )
      })}
    </div>
  )
}
