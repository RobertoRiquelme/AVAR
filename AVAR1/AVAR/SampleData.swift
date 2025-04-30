//
//  SampleData.swift
//  AVAR
//
//  Created by Roberto Riquelme on 22-04-25.
//

// SampleData.swift
let sampleJSON = """
{
  "scene": {
    "objects": [
      {
        "id": "tableTop",
        "type": "cube",
        "position": { "x": 0.0, "y": 0.75, "z": 0.0 },
        "size": { "width": 0.6, "height": 0.02, "depth": 0.4 },
        "color": "#A0522D",
        "metadata": { "label": "Table Surface" },
        "visible": true
      },
      {
        "id": "cube1",
        "type": "cube",
        "position": { "x": -0.2, "y": 0.8, "z": 0.0 },
        "size": { "width": 0.1, "height": 0.1, "depth": 0.1 },
        "rotation": { "x": 0, "y": 0, "z": 0 },
        "color": "#FF0000",
        "metadata": { "label": "Red Cube" },
        "visible": true
      },
      {
        "id": "sphere1",
        "type": "sphere",
        "position": { "x": 0.2, "y": 0.8, "z": 0.0 },
        "radius": 0.05,
        "color": "#00FF00",
        "metadata": { "label": "Green Sphere" },
        "visible": true
      },
      {
        "id": "cylinder1",
        "type": "cylinder",
        "position": { "x": 0.0, "y": 0.95, "z": 0.0 },
        "radius": 0.03,
        "height": 0.15,
        "rotation": { "x": 0, "y": 0, "z": 0 },
        "color": "#0000FF",
        "metadata": { "label": "Blue Cylinder" },
        "visible": true
      }
    ],
    "connections": [
      {
        "id": "conn1",
        "type": "line",
        "from": "cube1",
        "to": "sphere1",
        "color": "#AAAAAA",
        "thickness": 0.003,
        "metadata": { "label": "Link Cube to Sphere" }
      },
      {
        "id": "conn2",
        "type": "line",
        "from": "cube1",
        "to": "cylinder1",
        "color": "#AAAAAA",
        "thickness": 0.003
      }
    ]
  }
}
"""
