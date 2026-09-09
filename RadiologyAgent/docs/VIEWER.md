# Viewer controls

The right pane is a native AppKit viewport using DICOM pixels decoded and windowed by Horos. Routine 2D inspection stays inside Radiology Agent.

| Control | Action |
| --- | --- |
| W / window icon | Drag horizontally for width, vertically for level |
| P / hand icon | Drag to pan |
| Z / magnifier icon | Drag vertically to zoom around the starting point |
| S / stack icon | Drag vertically through the current series |
| Mouse wheel / two-finger vertical scroll | Previous/next frame within the current series |
| Pinch / Command-scroll | Zoom around the pointer |
| Space-drag / middle-drag | Temporary pan |
| Right-drag | Window/level regardless of the selected tool |
| F / double-click | Fit the image, preserving window/level |
| I | Invert grayscale |
| Arrow keys | Previous/next frame when the image viewport has focus |
| Window menu | Restore the DICOM default or choose a preset |

Shortcuts belong to the focused image view. Typing in the report or conversation does not manipulate images. The zoom label is relative to fit; it does not claim physical calibration or 1:1 pixel display.

Thumbnails select a series inline. Window and presentation settings persist while scrolling its slices. A series change resets presentation. **Open in Horos** explicitly opens the selected series and frame with the current rendered window settings; measurements, MPR, and 3D remain native Horos tools in a separate window.

Hover an underlined report phrase to preview its key image; leaving the phrase restores the pinned/current image. Click to pin. Use the key-image counter to cycle through multiple linked frames. Option-click a linked phrase to place the text caret and edit it. Editing its paragraph invalidates that image link so it cannot silently support a changed assertion.

The conversation button hides chat for image-focused reading. Images / Report / Split switch layouts; drag the split divider to resize images and the document. The study sidebar and conversation visibility persist between launches.

Astra's image selection and window settings are independent of the radiologist's viewer. Image inspection remains available during agent work; study changes and report edits remain locked until it finishes or is stopped.
