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

### v1: Python script + QT, all local

A single computer runs this monolithic Python + Qt module. The two source
modules (`timeline_app.py` entrypoint and `timeline_model.py` domain model)
are installed by `uv` into an ephemeral virtual env alongside the PySide6/Qt
runtime, and drawn to the local display.

```mermaid
flowchart TB
  subgraph dev["💻 Developer Workstation &laquo;device&raquo;"]
    subgraph uv["uv ephemeral venv &laquo;execution environment&raquo;"]
      app["timeline_app.py<br/>(PySide6 GUI: timeline + transport controls)<br/>&laquo;artifact&raquo;"]
      model["timeline_model.py<br/>(domain model)<br/>&laquo;artifact&raquo;"]
      qt["PySide6 / Qt runtime<br/>&laquo;artifact&raquo;"]
    end
    display["X11 / Wayland display<br/>&laquo;device&raquo;"]
  end

  app -->|imports| model
  app -->|renders via| qt
  qt -->|draws window| display
``` 