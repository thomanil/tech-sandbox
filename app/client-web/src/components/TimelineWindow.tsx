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
        // Same fade curve as the Qt client: fade = 1 - |offset|/(radius+1).
        const fade = 1 - Math.abs(offset) / (radius + 1)
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
                    : 'text-xl text-foreground',
                )}
                style={isCenter ? undefined : { opacity: 0.35 + 0.5 * fade }}
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
