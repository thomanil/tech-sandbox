# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "PySide6==6.8.3",
# ]
# ///

import sys

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


TICKS_PER_SECOND = 5
WINDOW_RADIUS = 4  # numbers shown on each side of the current value


class TimelineWidget(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.value = 0

        layout = QHBoxLayout(self)
        layout.setContentsMargins(20, 40, 20, 40)
        layout.setSpacing(16)
        layout.addStretch(1)

        self.labels: list[QLabel] = []
        for i in range(-WINDOW_RADIUS, WINDOW_RADIUS + 1):
            label = QLabel("")
            label.setAlignment(Qt.AlignCenter)
            label.setFixedWidth(70)
            self.labels.append(label)
            layout.addWidget(label)

        layout.addStretch(1)
        self.refresh()

    def set_value(self, value: int) -> None:
        self.value = max(0, value)
        self.refresh()

    def refresh(self) -> None:
        for offset, label in zip(
            range(-WINDOW_RADIUS, WINDOW_RADIUS + 1), self.labels
        ):
            n = self.value + offset
            if n < 0:
                label.setText("")
                label.setStyleSheet("")
                continue
            label.setText(str(n))
            if offset == 0:
                label.setFont(QFont("Helvetica", 36, QFont.Bold))
                label.setStyleSheet("color: #1f6feb;")
            else:
                fade = 1.0 - abs(offset) / (WINDOW_RADIUS + 1)
                gray = int(220 - 140 * fade)
                label.setFont(QFont("Helvetica", 20))
                label.setStyleSheet(f"color: rgb({gray}, {gray}, {gray});")


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Timeline")
        self.resize(720, 240)

        self.timeline = TimelineWidget()

        self.timer = QTimer(self)
        self.timer.setInterval(int(1000 / TICKS_PER_SECOND))
        self.timer.timeout.connect(self.on_tick)

        controls = QHBoxLayout()
        controls.addStretch(1)
        self.back_btn = self._make_button("⏮", self.on_back)
        self.play_btn = self._make_button("▶", self.on_play)
        self.stop_btn = self._make_button("■", self.on_stop)
        self.fwd_btn = self._make_button("⏭", self.on_forward)
        for b in (self.back_btn, self.play_btn, self.stop_btn, self.fwd_btn):
            controls.addWidget(b)
        controls.addStretch(1)

        root = QVBoxLayout()
        root.addWidget(self.timeline, 1)
        root.addLayout(controls)

        container = QWidget()
        container.setLayout(root)
        self.setCentralWidget(container)

    @staticmethod
    def _make_button(text: str, slot) -> QPushButton:
        btn = QPushButton(text)
        btn.setFixedSize(60, 40)
        btn.setFont(QFont("Helvetica", 16))
        btn.clicked.connect(slot)
        return btn

    def on_tick(self) -> None:
        self.timeline.set_value(self.timeline.value + 1)

    def on_play(self) -> None:
        if not self.timer.isActive():
            self.timer.start()

    def on_stop(self) -> None:
        self.timer.stop()

    def on_back(self) -> None:
        self.timeline.set_value(self.timeline.value - 1)

    def on_forward(self) -> None:
        self.timeline.set_value(self.timeline.value + 1)


def main() -> int:
    app = QApplication(sys.argv)
    win = MainWindow()
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
