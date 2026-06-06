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
and state out over one WebSocket — there are no REST endpoints.

Everything here runs on a single asyncio event loop: the WebSocket handler
coroutines, the ticker task, and broadcasts are cooperatively scheduled and
never truly parallel, so the shared `model`/`playing` state needs no locks.
"""

import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from timeline_model import SEQUENCES, TICKS_PER_SECOND, TimelineModel

# --- authoritative in-memory state -----------------------------------------

model = TimelineModel()  # owns per-sequence _indices + active sequence_name
playing = False


def state_message() -> dict:
    """The single message shape pushed to clients on connect and every change."""
    return {
        "type": "state",
        "window": model.visible_window(),
        "sequence_name": model.sequence_name,
        "sequences": list(SEQUENCES.keys()),
        "playing": playing,
    }


# --- connection tracking ----------------------------------------------------


class ConnectionManager:
    def __init__(self) -> None:
        self.active: set[WebSocket] = set()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self.active.add(ws)

    def disconnect(self, ws: WebSocket) -> None:
        self.active.discard(ws)

    async def broadcast(self, message: dict) -> None:
        # Iterate a snapshot; drop any socket that fails mid-send so one dead
        # client can't break the broadcast to the others.
        dead: list[WebSocket] = []
        for ws in list(self.active):
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.active.discard(ws)


manager = ConnectionManager()


# --- server-side playback ticker -------------------------------------------


async def ticker() -> None:
    """While playing, advance ONLY the active sequence and broadcast each tick.

    `model.step_forward()` writes `_indices[sequence_name]`, so inactive
    sequences stay frozen at their last position — never advance a global
    counter or loop over sequences here.
    """
    interval = 1 / TICKS_PER_SECOND
    while True:
        await asyncio.sleep(interval)
        if playing:
            model.step_forward()
            await manager.broadcast(state_message())


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(ticker())
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(lifespan=lifespan)


# --- command dispatch + websocket endpoint ---------------------------------


async def handle_command(msg: dict) -> None:
    global playing
    action = msg.get("action")
    if action == "forward":
        model.step_forward()
    elif action == "back":
        model.step_back()
    elif action == "play":
        playing = True
    elif action == "stop":
        playing = False
    elif action == "set_sequence":
        name = msg.get("name")
        if name not in SEQUENCES:
            return
        model.set_sequence(name)
    else:
        return  # unknown action -> no state change, no broadcast
    await manager.broadcast(state_message())


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket) -> None:
    await manager.connect(ws)
    await ws.send_json(state_message())  # initial full state to this client
    try:
        while True:
            msg = await ws.receive_json()
            await handle_command(msg)
    except WebSocketDisconnect:
        manager.disconnect(ws)
    except Exception:
        manager.disconnect(ws)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000)
