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


## Architecture

One uml deployment diagram per tagged version of this repo, 
showing how the app is deployed/distributed/run, and which moving parts exist

v1:

TODO add uml deployment diagram that is renderable in README locally and on github
It should show a single computer, running this monolithic python + qt module 