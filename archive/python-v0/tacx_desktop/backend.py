"""TrainerBackend interface shared by real FTMS BLE and demo stub."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Awaitable, Callable, Optional


class ConnectionState(Enum):
    DISCONNECTED = auto()
    SCANNING = auto()
    CONNECTING = auto()
    CONNECTED = auto()
    ERROR = auto()


class ControlMode(Enum):
    IDLE = auto()
    ERG = auto()
    RESISTANCE = auto()


@dataclass
class TrainerMetrics:
    power_w: float = 0.0
    cadence_rpm: float = 0.0
    speed_kmh: float = 0.0
    target_power_w: Optional[float] = None
    resistance_pct: Optional[float] = None


@dataclass
class ResistanceRange:
    """Supported Resistance Level Range (FTMS 0x2AD6), exposed as percent."""

    min_pct: float = 0.0
    max_pct: float = 100.0
    step_pct: float = 1.0


@dataclass
class PowerRange:
    min_w: int = 0
    max_w: int = 1000
    step_w: int = 1


@dataclass
class DiscoveredDevice:
    address: str
    name: str
    rssi: Optional[int] = None


MetricsCallback = Callable[[TrainerMetrics], None]
StateCallback = Callable[[ConnectionState, str], None]


@dataclass
class TrainerBackend(ABC):
    """Abstract trainer control + telemetry."""

    on_metrics: Optional[MetricsCallback] = field(default=None, repr=False)
    on_state: Optional[StateCallback] = field(default=None, repr=False)
    is_demo: bool = False

    @abstractmethod
    async def scan(self, timeout_s: float = 8.0) -> list[DiscoveredDevice]:
        ...

    @abstractmethod
    async def connect(self, address: Optional[str] = None) -> None:
        ...

    @abstractmethod
    async def disconnect(self) -> None:
        ...

    @abstractmethod
    async def request_control(self) -> None:
        ...

    @abstractmethod
    async def set_target_power(self, watts: int) -> None:
        ...

    @abstractmethod
    async def set_resistance(self, percent: float) -> None:
        ...

    @abstractmethod
    def get_metrics(self) -> TrainerMetrics:
        ...

    @abstractmethod
    def get_state(self) -> ConnectionState:
        ...

    @abstractmethod
    def get_mode(self) -> ControlMode:
        ...

    @abstractmethod
    def get_resistance_range(self) -> ResistanceRange:
        ...

    @abstractmethod
    def get_power_range(self) -> PowerRange:
        ...

    def _emit_metrics(self, metrics: TrainerMetrics) -> None:
        if self.on_metrics:
            self.on_metrics(metrics)

    def _emit_state(self, state: ConnectionState, detail: str = "") -> None:
        if self.on_state:
            self.on_state(state, detail)
