from datetime import datetime
from dataclasses import dataclass, field

@dataclass
class Emergency:
    latitude: float
    longitude: float
    battery_level: str
    timestamp: datetime = field(default_factory=datetime.now)
    assigned_team: str = "Unassigned"