import streamlit as st
import folium
from streamlit_folium import folium_static
from datetime import datetime
from emergency_model import Emergency

# Page configuration - wide layout makes the main area as wide as possible
st.set_page_config(page_title="Lifeline Emergency Dashboard", layout="wide")

# Initialize session state to store emergencies if it doesn't exist
if "emergencies" not in st.session_state:
    st.session_state.emergencies = [
        Emergency(latitude=40.1164, longitude=-88.2434, battery_level="48%"),
        Emergency(latitude=40.1138, longitude=-88.2249, battery_level="72%")
    ]

# Set a default view if not already set
if "selected_view" not in st.session_state:
    st.session_state.selected_view = "Active Emergencies"

# Title and description
st.title("Lifeline Emergency Dashboard")
st.markdown("Real-time monitoring of emergency situations")

# Prepare statistics for the clickable buttons
teams = set(e.assigned_team for e in st.session_state.emergencies if e.assigned_team != "Unassigned")
unassigned = sum(1 for e in st.session_state.emergencies if e.assigned_team == "Unassigned")
total_emergencies = len(st.session_state.emergencies)

# Clickable stats in columns (acting as buttons)
col1, col2, col3 = st.columns(3)
if col1.button(f"Active Emergencies: {total_emergencies}"):
    st.session_state.selected_view = "Active Emergencies"
if col2.button(f"Active Teams: {len(teams)}"):
    st.session_state.selected_view = "Active Teams"
if col3.button(f"Unassigned Emergencies: {unassigned}"):
    st.session_state.selected_view = "Unassigned Emergencies"

# Sidebar details based on the selected view
st.sidebar.markdown("### Details:")
if st.session_state.selected_view == "Active Emergencies":
    st.sidebar.markdown("#### All Emergencies")
    for i, emergency in enumerate(st.session_state.emergencies):
        st.sidebar.markdown(f"**Emergency #{i+1}**")
        st.sidebar.markdown(f"- **Time:** {emergency.timestamp.strftime('%Y-%m-%d %H:%M:%S')}")
        st.sidebar.markdown(f"- **Location:** {emergency.latitude}, {emergency.longitude}")
        st.sidebar.markdown(f"- **Battery:** {emergency.battery_level}")
        st.sidebar.markdown(f"- **Team:** {emergency.assigned_team}")
        st.sidebar.markdown("---")
elif st.session_state.selected_view == "Active Teams":
    st.sidebar.markdown("#### Teams and Their Emergencies")
    teams_dict = {}
    for emergency in st.session_state.emergencies:
        if emergency.assigned_team != "Unassigned":
            teams_dict.setdefault(emergency.assigned_team, []).append(emergency)
    if teams_dict:
        for team, emergencies in teams_dict.items():
            st.sidebar.markdown(f"**Team {team}**")
            st.sidebar.markdown(f"- **Current Assignments:** {len(emergencies)}")
            for j, em in enumerate(emergencies):
                st.sidebar.markdown(f"  - Emergency {j+1}: {em.timestamp.strftime('%Y-%m-%d %H:%M:%S')} at {em.latitude}, {em.longitude} (Battery: {em.battery_level})")
            st.sidebar.markdown("---")
    else:
        st.sidebar.markdown("No active teams.")
elif st.session_state.selected_view == "Unassigned Emergencies":
    st.sidebar.markdown("#### Unassigned Emergencies")
    unassigned_list = [e for e in st.session_state.emergencies if e.assigned_team == "Unassigned"]
    if unassigned_list:
        for i, emergency in enumerate(unassigned_list):
            st.sidebar.markdown(f"**Emergency #{i+1}**")
            st.sidebar.markdown(f"- **Time:** {emergency.timestamp.strftime('%Y-%m-%d %H:%M:%S')}")
            st.sidebar.markdown(f"- **Location:** {emergency.latitude}, {emergency.longitude}")
            st.sidebar.markdown(f"- **Battery:** {emergency.battery_level}")
            st.sidebar.markdown("---")
    else:
        st.sidebar.markdown("No unassigned emergencies.")

# Create a map centered at the first emergency (or a default location)
if st.session_state.emergencies:
    center_lat = st.session_state.emergencies[0].latitude
    center_lon = st.session_state.emergencies[0].longitude
else:
    center_lat, center_lon = 40.1164, -88.2434
m = folium.Map(location=[center_lat, center_lon], zoom_start=12)

# Add markers for each emergency with highlighting based on the selected view
for i, emergency in enumerate(st.session_state.emergencies):
    if st.session_state.selected_view == "Active Emergencies":
        highlighted = True
    elif st.session_state.selected_view == "Active Teams":
        highlighted = emergency.assigned_team != "Unassigned"
    elif st.session_state.selected_view == "Unassigned Emergencies":
        highlighted = emergency.assigned_team == "Unassigned"
    else:
        highlighted = False

    icon_color = "red" if highlighted else "blue"
    popup_text = f"""
    <b>Emergency #{i+1}</b><br>
    Battery: {emergency.battery_level}<br>
    Team: {emergency.assigned_team}<br>
    Time: {emergency.timestamp.strftime('%Y-%m-%d %H:%M:%S')}
    """
    folium.Marker(
        [emergency.latitude, emergency.longitude],
        popup=popup_text,
        tooltip=f"Emergency #{i+1}",
        icon=folium.Icon(color=icon_color, icon="info-sign")
    ).add_to(m)

# Display full width map (using a high width value so that it stretches under the sidebar as needed)
st.subheader("Emergency Locations")
folium_static(m, width=1200)

# Emergency team assignment remains below
st.subheader("Emergency Team Assignment")
for i, emergency in enumerate(st.session_state.emergencies):
    with st.expander(f"Emergency #{i+1} - {emergency.timestamp.strftime('%Y-%m-%d %H:%M:%S')}"):
        cols = st.columns([2, 1, 1, 1])
        with cols[0]:
            st.write(f"**Location**: {emergency.latitude}, {emergency.longitude}")
            st.write(f"**Battery**: {emergency.battery_level}")
        with cols[1]:
            team = st.selectbox(
                "Assign Team",
                options=["Unassigned", "Alpha", "Bravo", "Charlie", "Delta"],
                index=0 if emergency.assigned_team == "Unassigned" else
                      ["Unassigned", "Alpha", "Bravo", "Charlie", "Delta"].index(emergency.assigned_team),
                key=f"team_{i}"
            )
            if team != emergency.assigned_team:
                st.session_state.emergencies[i].assigned_team = team
                st.rerun()