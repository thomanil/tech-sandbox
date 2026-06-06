# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "fastapi==0.115.6",
#     "uvicorn[standard]==0.34.0",
# ]
# ///

"""WebSocket state server for the timeline app.

Single source of truth: this process owns the timeline state in memory
(per-sequence indices, the active sequence, and the play/pause flag) and runs
the playback ticker. The GUI client is a thin renderer that streams commands in
and state out over one WebSocket. The only REST route is GET /healthz, a
liveness/readiness probe for container orchestration (Docker/k8s).

Bind host/port come from the HOST/PORT env vars (default 127.0.0.1:8000) so the
container can publish on 0.0.0.0 without code changes; see Dockerfile.

Everything here runs on a single asyncio event loop: the WebSocket handler
coroutines, the ticker task, and broadcasts are cooperatively scheduled and
never truly parallel, so the shared `model`/`playing` state needs no locks.
"""

import asyncio
import logging
import sys
from contextlib import asynccontextmanager
from dataclasses import dataclass, field

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from timeline_model import SEQUENCES, TICKS_PER_SECOND, TimelineModel

# --- logging -----------------------------------------------------------------
#
# Dedicated logger writing to stdout, which Docker/k8s capture verbatim
# (`docker logs`, `kubectl logs`). It owns its own handler and does not
# propagate, so it works the same however the app is launched (uvicorn
# programmatically below, `uvicorn timeline_server:app`, or `uv run`) and never
# double-prints through uvicorn's root config. We log discrete client events
# (connects, playback commands) but deliberately NOT the ticker's auto-advance,
# which fires TICKS_PER_SECOND times a second per playing client.

logger = logging.getLogger("timeline")
if not logger.handlers:
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(
        logging.Formatter(
            "%(asctime)s %(levelname)s [timeline] %(message)s",
            datefmt="%H:%M:%S",
        )
    )
    logger.addHandler(_handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

# --- authoritative in-memory state ------------------------------------------
#
# State is per client, not global. Each client process generates an integer
# seed (its client id, sent as the ?client_id= URL param) and the server keeps
# one timeline + play flag per seed. State is keyed by seed and persists across
# reconnects, so a dropped-and-reopened client resumes where it left off; it is
# never evicted (a bounded, acceptable leak for a local dev demo).


@dataclass
class ClientState:
    model: TimelineModel = field(default_factory=TimelineModel)
    playing: bool = False


states: dict[int, ClientState] = {}


def get_state(client_id: int) -> ClientState:
    """The single place per-client state is born; called on connect and on every
    command, so a command can never hit a missing client."""
    state = states.get(client_id)
    if state is None:
        state = states[client_id] = ClientState()
    return state


def state_message(state: ClientState) -> dict:
    """The single message shape pushed to a client on connect and every change."""
    return {
        "type": "state",
        "window": state.model.visible_window(),
        "sequence_name": state.model.sequence_name,
        "sequences": list(SEQUENCES.keys()),
        "playing": state.playing,
    }


# --- connection tracking ----------------------------------------------------


class ConnectionManager:
    def __init__(self) -> None:
        # One client (seed) may briefly have several live sockets — e.g. a
        # reconnect that overlaps the dying old one — so map each id to a set.
        self.conns: dict[int, set[WebSocket]] = {}

    async def connect(self, ws: WebSocket, client_id: int) -> None:
        await ws.accept()
        self.conns.setdefault(client_id, set()).add(ws)

    def disconnect(self, ws: WebSocket, client_id: int) -> None:
        # Drop only the live socket; states[client_id] is deliberately kept so
        # the client resumes its timeline when it reconnects with the same seed.
        sockets = self.conns.get(client_id)
        if sockets is None:
            return
        sockets.discard(ws)
        if not sockets:
            del self.conns[client_id]

    async def send_to_client(self, client_id: int, message: dict) -> None:
        # Iterate a snapshot; drop any socket that fails mid-send so one dead
        # connection can't break delivery to this client's other sockets.
        dead: list[WebSocket] = []
        for ws in list(self.conns.get(client_id, set())):
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws, client_id)


manager = ConnectionManager()


# --- server-side playback ticker -------------------------------------------


async def ticker() -> None:
    """One driver for every client: each tick, advance only the clients that are
    currently playing and push each its own updated state.

    `model.step_forward()` writes `_indices[sequence_name]`, so a client's
    inactive sequences stay frozen at their last position. Iterate a snapshot of
    `states` because a connect/disconnect can mutate it across the `await`.
    """
    interval = 1 / TICKS_PER_SECOND
    while True:
        await asyncio.sleep(interval)
        for client_id, state in list(states.items()):
            if state.playing:
                state.model.step_forward()
                await manager.send_to_client(client_id, state_message(state))


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(ticker())
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(lifespan=lifespan)


# --- command dispatch + websocket endpoint ---------------------------------


async def handle_command(client_id: int, msg: dict) -> None:
    state = get_state(client_id)
    action = msg.get("action")
    m = state.model
    if action == "forward":
        m.step_forward()
        logger.info("client %s forward -> %s index %d", client_id, m.sequence_name, m.index)
    elif action == "back":
        m.step_back()
        logger.info("client %s back -> %s index %d", client_id, m.sequence_name, m.index)
    elif action == "play":
        state.playing = True
        logger.info("client %s play (%s @ index %d)", client_id, m.sequence_name, m.index)
    elif action == "stop":
        state.playing = False
        logger.info("client %s stop (%s @ index %d)", client_id, m.sequence_name, m.index)
    elif action == "set_sequence":
        name = msg.get("name")
        if name not in SEQUENCES:
            logger.warning("client %s set_sequence rejected: %r", client_id, name)
            return
        m.set_sequence(name)
        logger.info("client %s set_sequence -> %s", client_id, name)
    else:
        logger.warning("client %s unknown action: %r", client_id, action)
        return  # unknown action -> no state change, no send
    await manager.send_to_client(client_id, state_message(state))


@app.get("/healthz")
async def healthz() -> dict:
    """Liveness/readiness probe for Docker/k8s. Cheap and side-effect-free."""
    return {"status": "ok"}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket) -> None:
    # The client identifies itself with an integer seed in the URL
    # (ws://.../ws?client_id=<seed>); reject a connection without a valid one.
    try:
        client_id = int(ws.query_params.get("client_id"))
    except (TypeError, ValueError):
        await ws.close(code=1008)  # policy violation
        return

    # Resuming an existing seed vs. a brand-new one changes the connect message.
    known = client_id in states
    await manager.connect(ws, client_id)
    logger.info(
        "client %s %s -- %d connected %s, %d known",
        client_id,
        "reconnected" if known else "connected",
        len(manager.conns),
        sorted(manager.conns),
        len(states),
    )
    try:
        # Initial full state for this client (resumes prior state if seed is known).
        await ws.send_json(state_message(get_state(client_id)))
        while True:
            msg = await ws.receive_json()
            await handle_command(client_id, msg)
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        manager.disconnect(ws, client_id)
        logger.info(
            "client %s disconnected -- %d connected %s",
            client_id,
            len(manager.conns),
            sorted(manager.conns),
        )


if __name__ == "__main__":
    import os

    import uvicorn

    # Default to loopback for local dev; the container sets HOST=0.0.0.0.
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8000"))
    uvicorn.run(app, host=host, port=port)
