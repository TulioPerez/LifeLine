from datetime import datetime

class Emergency:
    def __init__(self, latitude, longitude, battery_level, file_identifier, assigned_team="Unassigned", timestamp_override=None, status="active"):
        self.latitude = latitude
        self.longitude = longitude
        self.battery_level = battery_level # Placeholder, e.g., "100%"
        self.assigned_team = assigned_team
        self.timestamp = timestamp_override if timestamp_override is not None else datetime.now()
        self.status = status  # "active" or "completed"
        self.file_identifier = file_identifier # The numeric part of the filename, e.g., "1746764427028659"

    def __repr__(self):
        return f"Emergency(ID={self.file_identifier}, Status={self.status}, Lat={self.latitude}, Lon={self.longitude}, Team={self.assigned_team}, Time={self.timestamp})"