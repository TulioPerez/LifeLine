import streamlit as st
import folium
from streamlit_folium import folium_static
from folium.plugins import MarkerCluster  # Import MarkerCluster
from datetime import datetime
from emergency_model import Emergency
import io
from streamlit_autorefresh import st_autorefresh
import requests  # For HTTP requests
import xml.etree.ElementTree as ET  # For XML parsing
import math  # For distance calculation

# --- Constants for GCS ---
BUCKET_NAME = "test_game_public"
BUCKET_URL = f"https://storage.googleapis.com/{BUCKET_NAME}/"  # XML API endpoint
DEFAULT_LATITUDE = 40.11
DEFAULT_LONGITUDE = -88.24  # West is negative
FILENAME_DIGIT_COUNT = 16

MAX_ASSIGNMENT_DISTANCE_MILES = 10.0
MAX_ASSIGNMENT_DISTANCE_KM = MAX_ASSIGNMENT_DISTANCE_MILES * 1.60934  # Approx conversion

# --- Helper Function for Distance (Haversine) ---
def haversine(lat1, lon1, lat2, lon2):
    R = 6371  # Radius of Earth in kilometers

    lat1_rad = math.radians(lat1)
    lon1_rad = math.radians(lon1)
    lat2_rad = math.radians(lat2)
    lon2_rad = math.radians(lon2)

    dlon = lon2_rad - lon1_rad
    dlat = lat2_rad - lat1_rad

    a = math.sin(dlat / 2)**2 + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(dlon / 2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

    distance = R * c
    return distance

# --- Function to update a team's location after an emergency completion ---
def update_team_operational_location(team_name, teams_state, all_emergencies_in_session):
    if team_name not in teams_state:
        return

    team_data = teams_state[team_name]
    active_assigned_emergencies = []

    # Find all active emergencies currently assigned to this team
    for em_id in team_data.get('assigned_emergency_ids', []):
        emergency_obj = next((em for em in all_emergencies_in_session if em.file_identifier == em_id and em.status == "active"), None)
        if emergency_obj:
            active_assigned_emergencies.append(emergency_obj)

    if not active_assigned_emergencies:
        team_data['current_lat'] = None  # Team is now free, location is undefined until next assignment
        team_data['current_lon'] = None
        team_data['last_emergency_timestamp'] = None
    else:
        # Sort by timestamp to find the most recent active assignment
        active_assigned_emergencies.sort(key=lambda em: em.timestamp, reverse=True)
        most_recent_em = active_assigned_emergencies[0]
        team_data['current_lat'] = most_recent_em.latitude
        team_data['current_lon'] = most_recent_em.longitude
        team_data['last_emergency_timestamp'] = most_recent_em.timestamp

# --- Helper to create a batch of 4 teams ---
def create_new_team_batch(new_emergency, teams_state, initial_assignment=True):
    batch_team_names = []
    for _ in range(4):
        next_team_num = st.session_state.get('next_team_number', 1)
        new_team_name = f"Team {next_team_num}"
        st.session_state.next_team_number = next_team_num + 1
        
        teams_state[new_team_name] = {
            'name': new_team_name,
            'current_lat': None, # Will be set if assigned
            'current_lon': None, # Will be set if assigned
            'assigned_emergency_ids': [],
            'last_emergency_timestamp': None
        }
        batch_team_names.append(new_team_name)

    if initial_assignment and batch_team_names:
        first_new_team_name = batch_team_names[0]
        teams_state[first_new_team_name]['current_lat'] = new_emergency.latitude
        teams_state[first_new_team_name]['current_lon'] = new_emergency.longitude
        teams_state[first_new_team_name]['assigned_emergency_ids'].append(new_emergency.file_identifier)
        teams_state[first_new_team_name]['last_emergency_timestamp'] = new_emergency.timestamp
        return first_new_team_name # Return the name of the team that got the assignment
    elif batch_team_names:
        return batch_team_names[0] # Return name of first for other uses if needed
    return None

# --- Automatic Team Assignment Logic (Dynamic Teams) ---
def assign_team_dynamically(new_emergency, all_emergencies_in_session, teams_state):
    # Case 1: No teams exist yet, create the first batch of 4
    if not teams_state:
        st.info("No teams exist. Creating initial batch of 4 teams.")
        assigned_team_name = create_new_team_batch(new_emergency, teams_state, initial_assignment=True)
        return assigned_team_name

    eligible_candidates = []

    # Evaluate existing teams
    for team_name, team_data in teams_state.items():
        load = len(team_data.get('assigned_emergency_ids', []))

        if load == 0:
            # Free team: always eligible, effectively 0 distance as it will relocate
            eligible_candidates.append({'name': team_name, 'load': 0, 'distance': 0.0})
        else:
            # Assigned team: check distance from its current location
            team_lat = team_data.get('current_lat')
            team_lon = team_data.get('current_lon')
            if team_lat is not None and team_lon is not None:
                distance = haversine(new_emergency.latitude, new_emergency.longitude, team_lat, team_lon)
                if distance <= MAX_ASSIGNMENT_DISTANCE_KM:
                    eligible_candidates.append({'name': team_name, 'load': load, 'distance': distance})

    # If there are eligible existing teams, assign to the best one
    if eligible_candidates:
        eligible_candidates.sort(key=lambda x: (x['load'], x['distance'])) # Sort by load, then distance
        best_candidate_info = eligible_candidates[0]
        chosen_team_name = best_candidate_info['name']
        
        # Update the chosen team's state
        team_to_update = teams_state[chosen_team_name]
        team_to_update['current_lat'] = new_emergency.latitude
        team_to_update['current_lon'] = new_emergency.longitude
        team_to_update.setdefault('assigned_emergency_ids', []).append(new_emergency.file_identifier)
        team_to_update['last_emergency_timestamp'] = new_emergency.timestamp
        return chosen_team_name
    else:
        # No existing team is eligible (all assigned teams are >10 miles away)
        # Create a new batch of 4 teams for this new operational area
        st.info(f"New emergency at {new_emergency.latitude:.2f},{new_emergency.longitude:.2f} is >10 miles from active teams. Creating new batch of 4 teams.")
        assigned_team_name = create_new_team_batch(new_emergency, teams_state, initial_assignment=True)
        return assigned_team_name

# --- Function to check GCS and update emergencies ---
def update_emergencies_from_gcs():
    changes_made = False
    try:
        # --- List files using requests and XML parsing ---
        response = requests.get(BUCKET_URL)
        response.raise_for_status()  # Will raise an exception for HTTP error codes

        root = ET.fromstring(response.content)
        current_gcs_file_identifiers = set()
        s3_namespace = "{http://doc.s3.amazonaws.com/2006-03-01}"  # Namespace for S3 XML

        for contents in root.findall(f"{s3_namespace}Contents"):
            key_element = contents.find(f"{s3_namespace}Key")
            if key_element is not None:
                blob_name = key_element.text
                if blob_name.endswith(".txt"):
                    identifier_part = blob_name[:-4]  # Remove .txt
                    if identifier_part.isdigit() and len(identifier_part) == FILENAME_DIGIT_COUNT:
                        current_gcs_file_identifiers.add(identifier_part)
        # --- End of listing files ---

        if "emergencies" not in st.session_state:
            st.session_state.emergencies = []
        if "teams" not in st.session_state:  # Initialize teams state
            st.session_state.teams = {}
        if "next_team_number" not in st.session_state:
            st.session_state.next_team_number = 1

        teams_state = st.session_state.teams  # Work with a reference

        # Mark existing emergencies as "completed" if their file is no longer in GCS
        for emergency in st.session_state.emergencies:
            if emergency.status == "active" and emergency.file_identifier not in current_gcs_file_identifiers:
                emergency.status = "completed"
                changes_made = True
                st.info(f"Emergency {emergency.file_identifier} (Team: {emergency.assigned_team}) marked as completed.")
                
                # Update the team it was assigned to
                if emergency.assigned_team and emergency.assigned_team in teams_state:
                    team_data = teams_state[emergency.assigned_team]
                    if emergency.file_identifier in team_data.get('assigned_emergency_ids', []):
                        team_data['assigned_emergency_ids'].remove(emergency.file_identifier)
                    # Re-evaluate team's operational location
                    update_team_operational_location(emergency.assigned_team, teams_state, st.session_state.emergencies)

        # Process active files from GCS: add new or update existing
        for file_id in current_gcs_file_identifiers:
            # print(f"Processing file: {file_id}") # Optional: for debugging
            existing_emergency = next((e for e in st.session_state.emergencies if e.file_identifier == file_id and e.status == "active"), None)

            if not existing_emergency:
                blob_name_to_fetch = f"{file_id}.txt"
                file_url = f"{BUCKET_URL}{blob_name_to_fetch}"

                file_response = requests.get(file_url)
                if not file_response.ok:
                    st.warning(f"File {blob_name_to_fetch} listed but could not be fetched (status: {file_response.status_code}). Skipping.")
                    continue

                content_string = file_response.text
                file_like_object = io.StringIO(content_string)

                file_latitude = DEFAULT_LATITUDE  # Initialize with default
                file_longitude = DEFAULT_LONGITUDE # Initialize with default
                file_timestamp_obj = None # Stores the timestamp of the first valid line
                first_valid_timestamp_found = False # Flag to ensure we only use the first timestamp
                gps_data_found_in_file = False # Flag to take the first GPS line

                for line_number, line in enumerate(file_like_object):
                    line = line.strip()
                    if not line:
                        continue
                    parts = line.split(',')
                    if len(parts) < 1:
                        continue

                    # Attempt to parse timestamp from the first part of the line
                    # We'll use the timestamp from the *first successfully parsed line* for the emergency
                    current_line_timestamp_str = parts[0].strip()
                    if not first_valid_timestamp_found:
                        try:
                            if current_line_timestamp_str.endswith('Z'):
                                file_timestamp_obj = datetime.fromisoformat(current_line_timestamp_str[:-1] + '+00:00')
                            else:
                                file_timestamp_obj = datetime.fromisoformat(current_line_timestamp_str)
                            first_valid_timestamp_found = True # Got the primary timestamp for the emergency
                        except ValueError:
                            if line_number == 0: # If first line's timestamp is bad, log it
                                st.warning(f"Invalid timestamp format on first line of {blob_name_to_fetch}: '{current_line_timestamp_str}'. Skipping file for timestamp.")
                                file_timestamp_obj = None # Ensure it's None if first line fails
                                break # Stop processing this file if its first line timestamp is bad
                            # For subsequent lines, we might still look for GPS even if their timestamp is off,
                            # but the emergency's main timestamp is already set from the first valid one.
                            pass # Continue to check for GPS if not the first line

                    # Check for GPS data on any line, but only use the first occurrence
                    if len(parts) > 1 and not gps_data_found_in_file:
                        sensor_type = parts[1].strip()
                        # Check for "GPS (last known)" specifically
                        if sensor_type == "GPS (last known)":
                            if len(parts) >= 4: # Need at least Timestamp, Type, Lat, Long
                                try:
                                    # parts[2] should be "Lat: value"
                                    # parts[3] should be "Long: value"
                                    lat_str_part = parts[2].strip()
                                    lon_str_part = parts[3].strip()

                                    if lat_str_part.startswith("Lat:") and lon_str_part.startswith("Long:"):
                                        lat_str = lat_str_part.split(':')[1].strip()
                                        lon_str = lon_str_part.split(':')[1].strip()
                                        
                                        parsed_lat = float(lat_str)
                                        parsed_lon = float(lon_str)

                                        # Use parsed GPS only if they are not (0.0, 0.0) unless explicitly desired
                                        # For now, we accept 0.0, 0.0 as valid if provided
                                        file_latitude = parsed_lat
                                        file_longitude = parsed_lon
                                        gps_data_found_in_file = True # Mark that we found and used GPS data
                                    else:
                                        st.warning(f"Malformed Lat/Long data in GPS line: '{line}' in file {blob_name_to_fetch}.")
                                except (ValueError, IndexError, TypeError) as e:
                                    st.warning(f"Could not parse GPS data from line: '{line}' in file {blob_name_to_fetch}. Error: {e}")
                                    pass # Keep default lat/lon if parsing fails for this GPS line
                            else:
                                st.warning(f"Insufficient parts for GPS data in line: '{line}' in file {blob_name_to_fetch}.")
                
                if file_timestamp_obj: # Proceed only if a valid timestamp was established for the emergency
                    temp_emergency_for_assignment = Emergency(
                        latitude=file_latitude,
                        longitude=file_longitude,
                        battery_level="100%", # Placeholder
                        timestamp_override=file_timestamp_obj,
                        file_identifier=file_id,
                        status="active",
                        assigned_team="PendingAssignment" # Temporary status
                    )
                    
                    # Assign team using the new dynamic logic
                    assigned_team_name = assign_team_dynamically(temp_emergency_for_assignment, st.session_state.emergencies, teams_state)

                    was_completed = next((e for e in st.session_state.emergencies if e.file_identifier == file_id and e.status == "completed"), None)
                    if was_completed:
                        was_completed.status = "active"
                        was_completed.timestamp = file_timestamp_obj
                        was_completed.latitude = file_latitude
                        was_completed.longitude = file_longitude
                        was_completed.assigned_team = assigned_team_name
                        st.success(f"Emergency {file_id} re-activated and assigned to {assigned_team_name}.")
                    else:
                        new_emergency_obj = Emergency(
                            latitude=file_latitude,
                            longitude=file_longitude,
                            battery_level="100%", # Placeholder
                            timestamp_override=file_timestamp_obj,
                            file_identifier=file_id,
                            status="active",
                            assigned_team=assigned_team_name
                        )
                        st.session_state.emergencies.append(new_emergency_obj)
                        st.success(f"New active emergency {file_id} added and assigned to {assigned_team_name}.")
                    changes_made = True
                else:
                    st.warning(f"Could not determine a valid timestamp for emergency file {blob_name_to_fetch}. Skipping.")

    except requests.exceptions.RequestException as e:
        st.error(f"Error during GCS communication (requests): {e}")
    except ET.ParseError as e:
        st.error(f"Error parsing GCS XML response: {e}")
    except Exception as e:
        st.error(f"An unexpected error occurred during GCS update: {e}")

    return changes_made

# Page configuration
st.set_page_config(page_title="Lifeline Emergency Dashboard", layout="wide")

# Initialize session state
if "emergencies" not in st.session_state: st.session_state.emergencies = []
if "teams" not in st.session_state: st.session_state.teams = {}
if "next_team_number" not in st.session_state: st.session_state.next_team_number = 1
if "selected_view" not in st.session_state: st.session_state.selected_view = "Active Emergencies"
# For manual reassignment dropdowns
if "manual_reassign_emergency_id" not in st.session_state: st.session_state.manual_reassign_emergency_id = None
if "manual_reassign_team_name" not in st.session_state: st.session_state.manual_reassign_team_name = None


# --- Auto-refresh setup ---
refresh_interval_seconds = 180
st_autorefresh(interval=refresh_interval_seconds * 1000, key="emergency_data_refresher")

# --- Check for new emergencies on every run (manual or auto-refreshed) ---
if update_emergencies_from_gcs():
    st.rerun()

# Title and description
st.title("Lifeline Emergency Dashboard")
st.markdown(f"Real-time monitoring of emergency situations")

# Prepare statistics for the clickable buttons
active_emergencies_list = [e for e in st.session_state.emergencies if e.status == "active"]
completed_emergencies_list = [e for e in st.session_state.emergencies if e.status == "completed"]
active_teams_count = sum(1 for team_data in st.session_state.teams.values() if team_data.get('assigned_emergency_ids'))
total_active_emergencies = len(active_emergencies_list)
total_completed_emergencies = len(completed_emergencies_list)

col1, col2, col3 = st.columns(3)
if col1.button(f"Active Emergencies: {total_active_emergencies}"):
    st.session_state.selected_view = "Active Emergencies"
if col2.button(f"Active Teams: {active_teams_count}"):
    st.session_state.selected_view = "Active Teams"
if col3.button(f"Completed Emergencies: {total_completed_emergencies}"):
    st.session_state.selected_view = "Completed Emergencies"


# Sidebar details based on the selected view
st.sidebar.markdown("### Details:")
sidebar_emergencies_to_filter = list(st.session_state.emergencies)

if st.session_state.selected_view == "Active Emergencies":
    st.sidebar.markdown("#### All Active Emergencies")
    display_list_sidebar = [e for e in sidebar_emergencies_to_filter if e.status == "active"]
elif st.session_state.selected_view == "Active Teams":
    st.sidebar.markdown("#### Teams and Their Active Emergencies")
    display_list_sidebar = [] 
    if not st.session_state.teams:
        st.sidebar.markdown("No teams currently active.")
    else:
        teams_with_assignments_sidebar = False
        for team_name, team_data in st.session_state.teams.items():
            assigned_ids = team_data.get('assigned_emergency_ids', [])
            if assigned_ids:
                teams_with_assignments_sidebar = True
                st.sidebar.markdown(f"**{team_name}** (At: {team_data.get('current_lat', 'N/A'):.2f}, {team_data.get('current_lon', 'N/A'):.2f})")
                st.sidebar.markdown(f"- Assignments: {len(assigned_ids)}")
        if not teams_with_assignments_sidebar:
            st.sidebar.markdown("No teams have active assignments.")
elif st.session_state.selected_view == "Completed Emergencies":
    st.sidebar.markdown("#### Completed Emergencies")
    display_list_sidebar = [e for e in sidebar_emergencies_to_filter if e.status == "completed"]
else: 
    display_list_sidebar = [e for e in sidebar_emergencies_to_filter if e.status == "active"]

if st.session_state.selected_view != "Active Teams":
    if not display_list_sidebar:
        st.sidebar.info(f"No emergencies to display for view: {st.session_state.selected_view}.")
    else:
        for i, emergency in enumerate(display_list_sidebar):
            st.sidebar.markdown(f"**Emergency ID: {emergency.file_identifier}** ({emergency.status})")
            st.sidebar.markdown(f"- **Time:** {emergency.timestamp.strftime('%Y-%m-%d %H:%M:%S')}")
            st.sidebar.markdown(f"- **Location:** {emergency.latitude:.4f}, {emergency.longitude:.4f}")
            st.sidebar.markdown(f"- **Battery:** {emergency.battery_level}")
            st.sidebar.markdown(f"- **Team:** {emergency.assigned_team}")
            st.sidebar.markdown("---")

# Create a map centered
map_center_list = [e for e in st.session_state.emergencies if e.status == "active"]
if map_center_list:
    center_lat = map_center_list[0].latitude
    center_lon = map_center_list[0].longitude
else:
    center_lat, center_lon = DEFAULT_LATITUDE, DEFAULT_LONGITUDE
m = folium.Map(location=[center_lat, center_lon], zoom_start=10)
marker_cluster = MarkerCluster(name="Active Emergencies", overlay=True, control=False, options={'maxClusterRadius': 30}).add_to(m)
active_emergencies_for_map = [e for e in st.session_state.emergencies if e.status == "active"]
if not active_emergencies_for_map:
    st.info("No active emergencies to display on the map.")
else:
    for i, emergency in enumerate(active_emergencies_for_map):
        highlighted = True
        if st.session_state.selected_view == "Completed Emergencies": highlighted = False
        elif st.session_state.selected_view == "Active Teams" and \
             (emergency.assigned_team == "PendingAssignment" or emergency.assigned_team not in st.session_state.teams):
             highlighted = False
        icon_color = "red" if highlighted else "darkblue"
        popup_text = f"<b>ID: {emergency.file_identifier}</b><br>Team: {emergency.assigned_team}<br>Time: {emergency.timestamp.strftime('%H:%M:%S')}"
        folium.Marker(location=[emergency.latitude, emergency.longitude], popup=popup_text, icon=folium.Icon(color=icon_color, icon="info-sign")).add_to(marker_cluster)
st.subheader("Emergency Locations (Active)")
folium_static(m, width=1200)


# --- Manual Team Re-assignment Section ---
st.subheader("Manual Team Re-assignment")
with st.expander("Re-assign an Emergency", expanded=False):
    active_emergency_ids = [em.file_identifier for em in active_emergencies_list]
    all_team_names = list(st.session_state.teams.keys())

    if not active_emergency_ids:
        st.info("No active emergencies to re-assign.")
    elif not all_team_names:
        st.info("No teams available to assign to.")
    else:
        selected_emergency_id = st.selectbox(
            "Select Active Emergency to Re-assign:",
            options=active_emergency_ids,
            key="manual_reassign_emergency_id_selector" # Unique key for selectbox
        )
        
        # Get current team for the selected emergency to set as default in team selector
        current_assigned_team = "None"
        emergency_to_reassign_obj = next((em for em in active_emergencies_list if em.file_identifier == selected_emergency_id), None)
        if emergency_to_reassign_obj:
            current_assigned_team = emergency_to_reassign_obj.assigned_team if emergency_to_reassign_obj.assigned_team in all_team_names else "None"
        
        # Ensure "None" (or a placeholder for unassign) is an option if needed, or just list teams
        team_options_for_reassign = ["None (Unassign)"] + all_team_names if "None (Unassign)" not in all_team_names else all_team_names
        
        try:
            current_team_index = team_options_for_reassign.index(current_assigned_team) if current_assigned_team in team_options_for_reassign else 0
        except ValueError:
            current_team_index = 0 # Default to first option if current team not found (e.g. "PendingAssignment")


        selected_team_name_for_reassign = st.selectbox(
            "Select New Team (or 'None' to Unassign):",
            options=team_options_for_reassign,
            index=current_team_index,
            key="manual_reassign_team_name_selector" # Unique key
        )

        if st.button("Re-assign Team", key="manual_reassign_button"):
            if selected_emergency_id and emergency_to_reassign_obj:
                old_team_name = emergency_to_reassign_obj.assigned_team
                new_team_name_actual = selected_team_name_for_reassign if selected_team_name_for_reassign != "None (Unassign)" else None

                if old_team_name == new_team_name_actual:
                    st.warning(f"Emergency {selected_emergency_id} is already assigned to {new_team_name_actual or 'Unassigned'}.")
                else:
                    # 1. Update old team (if exists and had this emergency)
                    if old_team_name and old_team_name in st.session_state.teams:
                        if selected_emergency_id in st.session_state.teams[old_team_name]['assigned_emergency_ids']:
                            st.session_state.teams[old_team_name]['assigned_emergency_ids'].remove(selected_emergency_id)
                        update_team_operational_location(old_team_name, st.session_state.teams, st.session_state.emergencies)
                    
                    # 2. Update emergency object
                    emergency_to_reassign_obj.assigned_team = new_team_name_actual

                    # 3. Update new team (if a team is chosen)
                    if new_team_name_actual and new_team_name_actual in st.session_state.teams:
                        st.session_state.teams[new_team_name_actual].setdefault('assigned_emergency_ids', []).append(selected_emergency_id)
                        # Ensure it's not duplicated if somehow already there
                        st.session_state.teams[new_team_name_actual]['assigned_emergency_ids'] = list(set(st.session_state.teams[new_team_name_actual]['assigned_emergency_ids']))
                        update_team_operational_location(new_team_name_actual, st.session_state.teams, st.session_state.emergencies)
                    
                    st.success(f"Emergency {selected_emergency_id} re-assigned from {old_team_name or 'Unassigned'} to {new_team_name_actual or 'Unassigned'}.")
                    st.rerun() # Rerun to reflect changes immediately
            else:
                st.error("Could not find the selected emergency for re-assignment.")


# Team Assignments Overview
st.subheader("Team Assignments Overview")
if not st.session_state.teams and not active_emergencies_list:
    st.info("No active emergencies or teams.")
elif not st.session_state.teams and active_emergencies_list:
    st.info("Emergencies active, but no teams formed yet or all unassigned.")
else:
    for team_name, team_data in st.session_state.teams.items():
        assigned_ids = team_data.get('assigned_emergency_ids', [])
        loc_lat = team_data.get('current_lat', 'N/A')
        loc_lon = team_data.get('current_lon', 'N/A')
        lat_str = f"{loc_lat:.2f}" if isinstance(loc_lat, float) else loc_lat
        lon_str = f"{loc_lon:.2f}" if isinstance(loc_lon, float) else loc_lon

        st.markdown(f"**{team_name} (Current Loc: {lat_str}, {lon_str})**")
        if assigned_ids:
            st.markdown(f"- Assigned Emergencies ({len(assigned_ids)}): {', '.join(assigned_ids)}")
        else:
            st.markdown("- No active assignments (Team is free)")
    
    unassigned_display = [e.file_identifier for e in active_emergencies_list if e.assigned_team is None or e.assigned_team == "PendingAssignment" or e.assigned_team not in st.session_state.teams]
    if unassigned_display:
        st.markdown(f"**Potentially Unassigned ({len(unassigned_display)}):** {', '.join(unassigned_display)}")
