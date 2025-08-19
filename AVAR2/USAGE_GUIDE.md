# AVAR2 Collaborative Sessions - Usage Guide

## Quick Start

### Setting Up Collaboration

1. **Launch AVAR2** on multiple visionOS devices
2. **Open the main window** (2D launcher interface)
3. **Locate the "Collaboration" section** (purple background)
4. **Tap "Start Collaboration"** on any device
5. **Other devices will automatically detect** the session

### Joining a Session

When a collaborative session is active nearby:
- Other AVAR2 apps will show the session automatically
- Tap the join prompt to enter the collaborative space
- You'll see "Connected (X participants)" status

## Core Features

### 🔗 Starting and Managing Sessions

#### Creating a Session
1. In the main window, find the purple "Collaboration" section
2. Tap "Start Collaboration" 
3. Wait for "Connected" status to appear
4. Other users can now join automatically

#### Session Status Indicators
- **"Not Connected"**: No active session
- **"Waiting for participants..."**: Session created, waiting for others
- **"Connected (X participants)"**: Active session with participant count
- **"Session ended"**: Session was terminated

#### Ending a Session
- Tap "End Session" in the collaboration section
- Only ends your participation, others can continue
- App returns to single-user mode

### 📊 Sharing Diagrams

#### Method 1: File-Based Diagrams
1. **Start a collaborative session**
2. **Select diagram** from the dropdown menu (e.g., "2D Tree Layout")
3. **Tap "Add Diagram"**
4. **Diagram appears instantly** on all participant devices

#### Method 2: JSON Input
1. **Switch to "From JSON" tab** in the main window
2. **Paste your JSON diagram data** in the text editor
3. **Tap "Validate JSON"** to ensure format is correct
4. **Tap "Add Diagram"**
5. **JSON data automatically syncs** to all participants

#### Method 3: HTTP Server
1. **Switch to "HTTP Server" tab**
2. **Tap "Start Server"** 
3. **Note the server URL** displayed
4. **Send diagram data via HTTP POST** to the URL
5. **Received diagrams appear on all participant devices**

Example HTTP request:
```bash
curl -X POST http://[device-ip]:8080/diagram \
  -H "Content-Type: application/json" \
  -d @my_diagram.json
```

### 🎯 Real-Time Interactions

#### Moving Diagrams
1. **Enter immersive space** (automatic on diagram addition)
2. **Look for the white grab handle** below each diagram
3. **Drag the grab handle** to move the entire diagram
4. **Position changes sync instantly** across all devices

#### Scaling Diagrams
1. **Locate the L-shaped zoom handle** in the bottom-right corner
2. **Drag diagonally** to zoom in/out
   - **Down-right**: Zoom in
   - **Up-left**: Zoom out
3. **Scale changes sync** to all participants

#### Rotating 3D Diagrams
1. **For 3D diagrams only**, find the **blue circular button** near the zoom handle
2. **Drag horizontally** to rotate the diagram on the Y-axis
3. **Rotation updates** appear on all participant devices

#### Moving Individual Elements (3D Diagrams)
1. **Grab any 3D element** directly (not available for 2D diagrams)
2. **Drag to reposition** within the diagram
3. **Connection lines update automatically**
4. **Element positions sync** across all participants

### 🌐 Immersion Control

#### Adjusting Immersion Levels
**From Main Window** (recommended for collaboration):
- Use the **Immersion Test Controls** buttons: 0%, 25%, 50%, 75%, 100%
- Changes broadcast to other participants as notifications

**From Immersive Space** (personal control):
- **Arrow keys**: Up/Down to adjust gradually
- **R key**: Reset to 0%
- **F key**: Full immersion (100%)
- **Spacebar**: Toggle debug info
- **Vertical drag gesture**: Smooth immersion control

#### Collaborative Immersion Behavior
- **Your changes**: Broadcast to other participants as notifications
- **Others' changes**: You see notifications but your immersion doesn't change
- **Individual control**: Each participant maintains their own immersion level

## Advanced Features

### 🔍 Surface Detection Integration

#### Snapping Diagrams to Surfaces
1. **Ensure "Show Plane Visualization" is enabled** (optional, for debugging)
2. **Drag diagrams near detected surfaces** (tables, walls, floors)
3. **Look for snap messages** above the grab handle:
   - "📍 Near Table - Release to Snap!"
   - "📍 Near Wall - Release to Snap!"
4. **Release to automatically snap** to the surface
5. **Snap positions sync** to all participants

#### Surface Types
- **2D Diagrams**: Prefer vertical surfaces (walls)
- **3D Diagrams**: Prefer horizontal surfaces (tables, floors)
- **All diagrams**: Can snap to any detected surface type

#### Snap Behavior
- **Wall mounting**: 2D diagrams orient perpendicular to wall
- **Table placement**: 3D diagrams rest on surface with proper height adjustment  
- **Ceiling mounting**: 2D diagrams flip for ceiling attachment

### 🌟 Multi-User Scenarios

#### Presenter + Audience Mode
1. **Presenter starts session** and adds diagrams
2. **Audience members join** and see all diagrams automatically
3. **Presenter controls** diagram positions and immersion
4. **Audience can view** from different angles simultaneously

#### Collaborative Editing
1. **Multiple users add diagrams** from different sources
2. **Anyone can reposition** diagrams in shared space
3. **Individual element editing** available for 3D diagrams
4. **Real-time updates** ensure everyone sees changes

#### Teaching/Training Scenarios
1. **Instructor prepares diagrams** via HTTP server or file selection
2. **Students join session** to see live demonstrations
3. **Interactive exploration** with individual immersion control
4. **Spatial positioning** allows multiple viewing perspectives

## Troubleshooting

### Common Issues

#### "Start Collaboration" Doesn't Work
**Possible Causes**:
- Device not connected to network
- GroupActivity permissions disabled
- Multiple apps trying to create sessions simultaneously

**Solutions**:
1. Check **Settings > Privacy & Security > GroupActivity**
2. Ensure devices are on **same WiFi network** or **same Apple ID**
3. **Restart the app** and try again
4. Try from a **different device** first

#### Diagrams Not Appearing on Other Devices
**Possible Causes**:
- Network connectivity issues
- Session not properly established
- Large diagram data transmission delays

**Solutions**:
1. **Check session status** shows "Connected (X participants)"
2. **Verify network connection** is stable
3. **Wait a few seconds** for large diagrams
4. **Try smaller test diagram** first

#### Position Updates Delayed
**Possible Causes**:
- Network latency
- Multiple simultaneous position changes
- Device performance issues

**Solutions**:
1. **Reduce movement speed** when positioning diagrams
2. **Check network signal strength**
3. **Minimize other network usage**
4. **One person moves at a time** for best results

#### Session Drops Participants
**Possible Causes**:
- Network connection interruption
- Device going to sleep/background
- App switching or multitasking

**Solutions**:
1. **Keep app in foreground** during collaboration
2. **Maintain stable network connection**
3. **Restart collaboration** if connection drops
4. **Check device power settings**

### Debug Features

#### Enable Debug Information
1. **In immersive space**, press **Spacebar** to toggle debug info
2. Shows **FPS, entity counts, and system status**
3. Useful for **performance troubleshooting**

#### Check Network Status
1. **Monitor session status** in main window
2. **Watch for error messages** in collaboration section
3. **Verify participant count** matches expected number

#### Test with Simple Content
1. **Start with basic diagrams** (smaller JSON files)
2. **Test position updates** before adding complex content
3. **Verify each feature works** before combining

## Best Practices

### 🎯 Session Management

#### Starting Sessions
- **Designate one person** to start the session initially
- **Wait for "Connected" status** before adding diagrams
- **Confirm all participants joined** before beginning work

#### During Collaboration
- **Communicate verbally** when making major changes
- **Move diagrams slowly** for better sync performance
- **Take turns** when repositioning multiple diagrams

#### Ending Sessions
- **Announce when ending** the session to other participants
- **Save important work** before leaving collaboration
- **Exit immersive space** before ending session for clean shutdown

### 📊 Content Sharing

#### Diagram Preparation
- **Test diagrams individually** before sharing
- **Use descriptive filenames** for easy identification
- **Keep JSON data reasonably sized** (under 1MB recommended)

#### Positioning Strategy
- **Spread diagrams apart** to avoid overlapping
- **Use consistent heights** for easier viewing
- **Consider viewing angles** for all participants

#### Performance Tips
- **Limit total number** of active diagrams (recommend < 10)
- **Remove unused diagrams** using close button (×)
- **Monitor frame rate** in debug mode

### 🌐 Network Considerations

#### Connection Requirements
- **Stable WiFi recommended** over cellular
- **Same network preferred** for best performance
- **Low latency important** for real-time interactions

#### Bandwidth Usage
- **Initial diagram sharing** uses most bandwidth
- **Position updates** are lightweight
- **Consider network limits** with large groups

## Tips and Tricks

### 🚀 Efficiency Tips

#### Quick Collaboration Setup
1. **Pre-load diagrams** before starting session
2. **Use file-based diagrams** for fastest sharing
3. **Test network setup** with simple content first

#### Smooth Positioning
1. **Use grab handle** instead of direct entity dragging
2. **Move slowly** for better synchronization
3. **Wait for visual confirmation** before next move

#### Multi-Perspective Viewing
1. **Each participant can have different immersion levels**
2. **Move around diagrams** for different viewing angles
3. **Use surface snapping** for stable reference points

### 🎨 Creative Uses

#### Interactive Presentations
- **Presenter adds diagrams dynamically** via HTTP
- **Audience explores** from individual perspectives
- **Questions answered** by repositioning relevant diagrams

#### Collaborative Analysis
- **Multiple team members** add related diagrams
- **Spatial arrangement** shows relationships
- **Interactive exploration** of complex data

#### Remote Training
- **Instructor demonstrates** concepts with 3D models
- **Students follow along** from different locations
- **Hands-on practice** with individual diagram manipulation

---

**Need More Help?**

Check the console logs for detailed error messages and refer to the API Reference documentation for advanced customization options.