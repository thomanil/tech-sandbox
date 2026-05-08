TICKS_PER_SECOND = 5
WINDOW_RADIUS = 4  # numbers shown on each side of the current value


class TimelineModel:
    def __init__(self, start: int = 0):
        self.value = max(0, start)

    def step_forward(self) -> None:
        self.value += 1

    def step_back(self) -> None:
        self.value = max(0, self.value - 1)

    def visible_window(self) -> list[int | None]:
        """Return the numbers visible in the timeline window.

        Each entry is an int, or None if it would be negative.
        """
        return [
            n if n >= 0 else None
            for n in range(
                self.value - WINDOW_RADIUS, self.value + WINDOW_RADIUS + 1
            )
        ]
