# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "PySide6==6.8.3",
# ]
# ///

"""Thin WebSocket GUI client for the timeline app.

This process holds NO authoritative state. It connects to the state server over
one WebSocket (QtWebSockets, integrated with the Qt event loop — no polling
timer, no background thread): it renders whatever timeline window the server
pushes, and sends command messages when the user clicks a control. The server
owns the state and the playback clock; see timeline_server.py.
"""

import json
import sys

from PySide6.QtCore import Qt, QTimer, QUrl
from PySide6.QtGui import QFont
from PySide6.QtNetwork import QAbstractSocket
from PySide6.QtWebSockets import QWebSocket
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

# Server environments the client can connect to. Only Local is wired up for
# now; uncomment/add Staging and Production here when those backends exist.
SERVERS = {
    "Local": "ws://127.0.0.1:8000/ws",
    # "Staging": "ws://staging.internal:8000/ws",
    # "Production": "wss://timeline.example.com/ws",
}
DEFAULT_SERVER = "Local"


class TimelineWidget(QWidget):
    """Renders a timeline window pushed from the server. Holds no state."""

    def __init__(self, parent=None):
        super().__init__(parent)

        self._layout = QHBoxLayout(self)
        self._layout.setContentsMargins(20, 40, 20, 40)
        self._layout.setSpacing(16)
        self._layout.addStretch(1)
        # Stretch goes back in after the labels; labels are built lazily on the
        # first window so the count matches without knowing WINDOW_RADIUS here.
        self._layout.addStretch(1)

        self.labels: list[QLabel] = []

    def _ensure_labels(self, count: int) -> None:
        if len(self.labels) == count:
            return
        for label in self.labels:
            self._layout.removeWidget(label)
            label.deleteLater()
        self.labels = []
        # Insert each new label before the trailing stretch (last item).
        for _ in range(count):
            label = QLabel("")
            label.setAlignment(Qt.AlignCenter)
            # Minimum (not fixed) width: keeps spacing for small numbers but
            # lets cells grow so large Fibonacci/prime values aren't truncated.
            label.setMinimumWidth(70)
            self.labels.append(label)
            self._layout.insertWidget(self._layout.count() - 1, label)

    def render_window(self, window: list) -> None:
        """Draw the server-provided window: center value bold/blue, neighbors fade."""
        self._ensure_labels(len(window))
        radius = (len(window) - 1) // 2
        for offset, (n, label) in enumerate(zip(window, self.labels)):
            offset_from_center = offset - radius
            if n is None:
                label.setText("")
                label.setStyleSheet("")
                continue
            label.setText(str(n))
            if offset_from_center == 0:
                label.setFont(QFont("Helvetica", 36, QFont.Bold))
                label.setStyleSheet("color: #1f6feb;")
            else:
                fade = 1.0 - abs(offset_from_center) / (radius + 1)
                gray = int(220 - 140 * fade)
                label.setFont(QFont("Helvetica", 20))
                label.setStyleSheet(f"color: rgb({gray}, {gray}, {gray});")


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Timeline (connecting…)")
        self.resize(720, 240)

        self.timeline = TimelineWidget()

        # Guards against the combo's currentTextChanged firing when we set it
        # programmatically from a server state message (would echo a bogus
        # set_sequence command back).
        self._suppress_combo = False
        self._combo_ready = False

        # Which backend we talk to; switched live via the Server dropdown.
        self._server_url = SERVERS[DEFAULT_SERVER]
        # Guards against the server combo's change signal firing while we
        # populate it (would trigger a spurious reconnect).
        self._suppress_server_combo = False

        # Banner shown when the server is unreachable; hidden while connected.
        self.status_label = QLabel("")
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setWordWrap(True)
        self.status_label.hide()

        selector = QHBoxLayout()
        selector.addStretch(1)
        selector.addWidget(QLabel("Server:"))
        self.server_combo = QComboBox()
        # Populate up front (client-side static list) under the suppress guard
        # so it doesn't fire a reconnect before we've even connected.
        self._suppress_server_combo = True
        self.server_combo.addItems(list(SERVERS.keys()))
        self.server_combo.setCurrentText(DEFAULT_SERVER)
        self._suppress_server_combo = False
        self.server_combo.currentTextChanged.connect(self.on_server_changed)
        selector.addWidget(self.server_combo)
        selector.addSpacing(24)
        selector.addWidget(QLabel("Sequence:"))
        self.sequence_combo = QComboBox()
        self.sequence_combo.currentTextChanged.connect(self.on_sequence_changed)
        selector.addWidget(self.sequence_combo)
        selector.addStretch(1)

        controls = QHBoxLayout()
        controls.addStretch(1)
        self.back_btn = self._make_button("⏮", self.on_back)
        self.play_btn = self._make_button("▶", self.on_play)
        self.stop_btn = self._make_button("■", self.on_stop)
        self.fwd_btn = self._make_button("⏭", self.on_forward)
        for b in (self.back_btn, self.play_btn, self.stop_btn, self.fwd_btn):
            controls.addWidget(b)
        controls.addStretch(1)

        # Controls disabled until connected, so it's clear they do nothing offline.
        self.controls = [
            self.back_btn,
            self.play_btn,
            self.stop_btn,
            self.fwd_btn,
            self.sequence_combo,
        ]

        root = QVBoxLayout()
        root.addWidget(self.status_label)
        root.addWidget(self.timeline, 1)
        root.addLayout(selector)
        root.addLayout(controls)

        container = QWidget()
        container.setLayout(root)
        self.setCentralWidget(container)

        self.ws = QWebSocket()
        self.ws.textMessageReceived.connect(self.on_message)
        self.ws.connected.connect(self.on_connected)
        self.ws.disconnected.connect(self.on_disconnected)
        self.ws.errorOccurred.connect(self.on_error)

        # Retry the connection while the server is down so the client recovers
        # on its own once the server comes back up.
        self.reconnect_timer = QTimer(self)
        self.reconnect_timer.setInterval(2000)
        self.reconnect_timer.timeout.connect(self._try_connect)

        self._set_offline("Connecting to server…", is_error=False)
        self._try_connect()

    @staticmethod
    def _make_button(text: str, slot) -> QPushButton:
        btn = QPushButton(text)
        btn.setFixedSize(60, 40)
        btn.setFont(QFont("Helvetica", 16))
        btn.clicked.connect(slot)
        return btn

    # --- websocket lifecycle -----------------------------------------------

    def _try_connect(self) -> None:
        # Only (re)open when fully closed; avoids stacking connection attempts.
        if self.ws.state() == QAbstractSocket.SocketState.UnconnectedState:
            self.ws.open(QUrl(self._server_url))

    def _set_offline(self, message: str, is_error: bool) -> None:
        """Show the status banner, disable controls, and keep retrying."""
        colors = (
            ("#b91c1c", "#fee2e2") if is_error else ("#92400e", "#fef3c7")
        )
        fg, bg = colors
        prefix = "⚠ " if is_error else ""
        self.status_label.setText(prefix + message)
        self.status_label.setStyleSheet(
            f"color: {fg}; background: {bg}; padding: 6px; border-radius: 4px;"
        )
        self.status_label.show()
        for w in self.controls:
            w.setEnabled(False)
        if not self.reconnect_timer.isActive():
            self.reconnect_timer.start()

    def on_connected(self) -> None:
        self.setWindowTitle("Timeline")
        self.reconnect_timer.stop()
        self.status_label.hide()
        for w in self.controls:
            w.setEnabled(True)

    def on_disconnected(self) -> None:
        # Keep the last-rendered window on screen; flag the state and retry.
        self.setWindowTitle("Timeline (disconnected)")
        self._set_offline("Lost connection to server. Reconnecting…", is_error=True)

    def on_error(self, _error) -> None:
        self.setWindowTitle("Timeline (disconnected)")
        self._set_offline(
            f"Cannot reach server at {self._server_url}. "
            "Is timeline_server.py running? Retrying…",
            is_error=True,
        )

    def on_message(self, text: str) -> None:
        state = json.loads(text)
        if state.get("type") != "state":
            return
        self._sync_combo(state["sequences"], state["sequence_name"])
        self.timeline.render_window(state["window"])

    def _sync_combo(self, sequences: list, active: str) -> None:
        """Populate the combo once, then keep it synced to the server's active
        sequence — always under the suppress guard so it never echoes a command."""
        self._suppress_combo = True
        if not self._combo_ready:
            self.sequence_combo.addItems(sequences)
            self._combo_ready = True
        if self.sequence_combo.currentText() != active:
            self.sequence_combo.setCurrentText(active)
        self._suppress_combo = False

    # --- command senders ---------------------------------------------------

    def _send(self, payload: dict) -> None:
        self.ws.sendTextMessage(json.dumps(payload))

    def on_play(self) -> None:
        self._send({"type": "command", "action": "play"})

    def on_stop(self) -> None:
        self._send({"type": "command", "action": "stop"})

    def on_back(self) -> None:
        self._send({"type": "command", "action": "back"})

    def on_forward(self) -> None:
        self._send({"type": "command", "action": "forward"})

    def on_sequence_changed(self, name: str) -> None:
        if self._suppress_combo:
            return
        self._send({"type": "command", "action": "set_sequence", "name": name})

    def on_server_changed(self, name: str) -> None:
        """Switch which backend we talk to: tear down the current connection and
        reconnect to the chosen environment's URL."""
        if self._suppress_server_combo:
            return
        self._server_url = SERVERS[name]
        self.reconnect_timer.stop()
        self.ws.abort()  # drop the current connection immediately
        self._set_offline(f"Connecting to {name}…", is_error=False)
        self._try_connect()


def main() -> int:
    app = QApplication(sys.argv)
    win = MainWindow()
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
