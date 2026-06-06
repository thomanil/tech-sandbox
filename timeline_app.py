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
    QComboBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from timeline_model import (
    SEQUENCES,
    TICKS_PER_SECOND,
    WINDOW_RADIUS,
    TimelineModel,
)


class TimelineWidget(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.model = TimelineModel()

        layout = QHBoxLayout(self)
        layout.setContentsMargins(20, 40, 20, 40)
        layout.setSpacing(16)
        layout.addStretch(1)

        self.labels: list[QLabel] = []
        for _ in range(2 * WINDOW_RADIUS + 1):
            label = QLabel("")
            label.setAlignment(Qt.AlignCenter)
            # Minimum (not fixed) width: keeps spacing for small numbers but
            # lets cells grow so large Fibonacci/prime values aren't truncated.
            label.setMinimumWidth(70)
            self.labels.append(label)
            layout.addWidget(label)

        layout.addStretch(1)
        self.refresh()

    def refresh(self) -> None:
        window = self.model.visible_window()
        for offset, (n, label) in enumerate(zip(window, self.labels)):
            offset_from_center = offset - WINDOW_RADIUS
            if n is None:
                label.setText("")
                label.setStyleSheet("")
                continue
            label.setText(str(n))
            if offset_from_center == 0:
                label.setFont(QFont("Helvetica", 36, QFont.Bold))
                label.setStyleSheet("color: #1f6feb;")
            else:
                fade = 1.0 - abs(offset_from_center) / (WINDOW_RADIUS + 1)
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

        selector = QHBoxLayout()
        selector.addStretch(1)
        selector.addWidget(QLabel("Sequence:"))
        self.sequence_combo = QComboBox()
        self.sequence_combo.addItems(list(SEQUENCES.keys()))
        self.sequence_combo.setCurrentText(self.timeline.model.sequence_name)
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

        root = QVBoxLayout()
        root.addWidget(self.timeline, 1)
        root.addLayout(selector)
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
        self.timeline.model.step_forward()
        self.timeline.refresh()

    def on_play(self) -> None:
        if not self.timer.isActive():
            self.timer.start()

    def on_stop(self) -> None:
        self.timer.stop()

    def on_back(self) -> None:
        self.timeline.model.step_back()
        self.timeline.refresh()

    def on_forward(self) -> None:
        self.timeline.model.step_forward()
        self.timeline.refresh()

    def on_sequence_changed(self, name: str) -> None:
        self.timeline.model.set_sequence(name)
        self.timeline.refresh()


def main() -> int:
    app = QApplication(sys.argv)
    win = MainWindow()
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
