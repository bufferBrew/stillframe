# Stillframe

Stillframe captures and annotates screenshots, stitches scrolling content, and records your screen on macOS. It uses AppKit, SwiftUI, ScreenCaptureKit, and Vision. Captures and OCR stay on your Mac.

Requires **macOS 15+** and Xcode with a macOS 15 or newer SDK. The scripts use `/Applications/Xcode.app` when present. Set `DEVELOPER_DIR` to use a different Xcode installation.

## Build and launch

```sh
./build.sh
open Stillframe.app
```

The build assembles and ad-hoc signs a local `Stillframe.app` in this directory. Drag the app to Applications yourself if desired. Rebuilding an ad-hoc signed app may require regranting screen permission.

## Use

- **Area / Window / Screen:** select a region, a window, or the main display. Every completed screenshot is automatically copied to the clipboard as PNG and TIFF, as well as saved in your library. Area selection supports Return for the whole display. Escape cancels interactive capture. Timer offers 3, 5, or 10 seconds to prepare your capture.
- **Settings:** open the gear button or Command–comma. Record your own shortcuts (or use key/modifier selectors), configure capture delay, cursor/shadows, open-editor behavior, default PNG/JPEG export, recording frame rate/resolution/audio, and default background. Apply saves changes locally; unavailable shortcut combinations leave the previous bindings active.
- **Global shortcuts:** Control–Command–Shift–4 captures an area; Control–Command–Shift–3 captures the main display; Control–Command–Shift–5 starts/stops recording; Control–Command–Shift–6 starts scrolling capture or adds a frame to an active scrolling capture; Control–Command–Shift–Return finishes and copies the combined screenshot. All five can be changed in Settings. Option combinations, F1–F20, navigation keys, and punctuation are supported; macOS-reserved shortcuts may be unavailable. Recommended shortcuts can be restored with one button. Older three-shortcut configurations are migrated without replacing your choices. Stillframe stays in the menu bar when its window closes.
- **Import / Paste Image:** open an image with Command–O, or paste an image using Shift–Command–V. Import works without screen permissions.
- **Annotate:** select a tool and drag on the image. Arrow, rectangle, ellipse, pencil, highlight, solid redaction, text and numbered steps are available. Click to place text or a step. Set the annotation text before placing it.
- **Crop:** drag the desired region. Crop flattens existing marks; Undo restores the previous image and editable marks. Undo/Redo use Command–Z / Shift–Command–Z and apply during the current editing session.
- **Backdrop:** toggle padding around your image. The palette menu offers Ocean, Sunset, Graphite, Paper, a custom background image, and padding presets. Each capture keeps its own background and supports Undo/Redo; imported background images are embedded (maximum 2048px edge).
- **Copy Text:** recognize text on-device with Vision and copy it. OCR uses the edited image, respecting redactions.
- **Copy / Export:** copy the rendered image (Shift–Command–C) or save a PNG/JPEG (Command–S). The capture overlay also supports dragging the edited preview into other apps.
- **Pin:** keep a resizable copy above other windows.
- **History:** captures and edits survive relaunch. Search by name and filter images/videos. Right-click to rename, reveal, or delete a capture.
- **Record:** record the main display as H.264 MP4 at up to 3840 × 2160, with 15, 30, or 60 fps capture settings and optional system audio. Stillframe's windows are excluded. Stop from the editor, menu bar, or global shortcut, then play or export the finished video. Quitting while the recorder is busy is blocked to protect its output.

## Scrolling capture

Choose **Scroll** (or File → Scrolling Capture / Add Frame), then drag a rectangle around the scrolling content. The first frame is captured automatically. Scroll **down** about half a screen in the target app, choose **Add Frame**, and repeat. **Finish** saves the combined image to your library and copies it to the clipboard for annotation and export; Cancel discards the in-progress session.

To continue a screenshot you just took, choose **Extend with Scrolling** from its capture overlay, **Extend…** in the editor, or the library's right-click menu. New area/fullscreen captures remember their region, so extension reuses it automatically. Older, window, imported or cropped screenshots ask you to select the original region again (Return selects the full display). The original screenshot becomes frame 1. Scroll down in the target app, press **Control–Command–Shift–6** to append a frame, and **Control–Command–Shift–Return** to finish and copy. Existing annotations/redactions are flattened into the seed and preserved; decorative backgrounds are excluded from matching. The original library item is retained.

Keep the region/scale unchanged and leave overlapping content visible. Exclude fixed headers, floating controls and scrollbars where possible. Stillframe matches overlapping image rows and rejects duplicate, missing or ambiguous matches. If automatic matching fails on repetitive content, enable **Set overlap manually** and specify the percentage of the new frame already visible in the previous one. This is a guided workflow: you scroll and choose when to sample; it does not inject scrolling events or require Accessibility access. Currently vertical/downward only, with an 80-megapixel output limit.

## Video clips and GIFs

Select a recording in the library. Set **Start** and **End** in seconds, or use the sliders. **Preview clip** plays the selected range; **Export Clip** creates a trimmed MP4, preserving the original. **Original MP4** exports the complete recording.

**Export GIF** creates a looping, silent animated GIF from the same range. Choose 5/10/15 fps and a maximum edge of 480/720/1080px. GIFs support clips up to 30 seconds; select a shorter range for longer recordings. Export shows progress and supports cancellation. Existing destination files are replaced only after a successful export; exporting over the source recording is blocked.

## Screen permissions

The first capture or recording requires **System Settings → Privacy & Security → Screen & System Audio Recording → Stillframe**. Enable access, then quit and reopen Stillframe when macOS requests it. No Accessibility permission or microphone access is needed. Timer capture hides the app while you prepare the screen.

## Local data

`~/Library/Application Support/Stillframe/history.json` stores capture metadata and editable annotations. PNG/MP4 files are alongside it. Files are local and unencrypted. The original screenshot remains available for editing: **redaction removes source pixels in flattened copies/exports, but does not erase the original from your capture library.** Delete the capture to remove its library source. Cropping replaces the library image; the current session can undo it. Undo history is not persisted between launches. `preferences.json` stores settings, including global shortcut bindings and default background assets. Existing capture history remains compatible with 0.1.0.

## Scope

This is a working independent implementation of the core local capture workflow, not full CleanShot parity. Webcam/microphone recording, automatic scrolling, horizontal stitching, Studio Mode/zoom editing, and cloud hosting/collaboration are not implemented. Recording currently targets the main display; area screenshots use Stillframe’s region picker and window screenshots use the macOS window picker.

## Tests

```sh
./test.sh
```

Tests cover unconditional PNG clipboard publication even with an old opt-out setting, shortcut migration/function keys/punctuation, extension redaction/region retention, flattened redaction, crop orientation/bounds, annotations, history, settings recovery and persistence, per-capture backgrounds, legacy metadata, shortcut validation, three-frame scroll stitching, real MP4 trimming and GIF decoding, destination replacement, source preservation, invalid ranges and export cancellation. Run the full suite from a regular macOS terminal session. The clipboard and video export integration tests require access to the system pasteboard and H.264 encoder. Live screen capture and recording require macOS permissions.

## Credits

Stillframe was inspired by the capture workflows described on the [CleanShot X website](https://cleanshot.com/features). Stillframe uses native Apple APIs.
