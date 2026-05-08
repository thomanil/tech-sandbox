# tech-sandbox

Simple playground and example sandbox for some tech, tools and techniques.

## timeline_app

Small PySide6 GUI with a centered scrolling number timeline and CD-style
playback controls (back / play / stop / forward). Play advances 5 ticks per
second.

Launch:

```
uv run timeline_app.py
```

Dependencies are declared inline in the script (PEP 723), so `uv` installs
PySide6 into an ephemeral env on first run — no separate `pip install` step
needed.
