# Poach app icon

The master in `PoachIcon.png` shows a matte orange pouch on a cobalt tile. The belly is round, the lime band defines the neck, and the soft collar rises on the right. The app build scales this master into the Dock and Finder icon sizes. The Capture header uses the application icon.

At 18 points, the menu bar uses two solid lobes with a transparent gap for the cinch. The higher right tip preserves the collar’s direction. Keep the coordinates in `PoachMenuBar.svg` and `PoachMark.swift` in sync.

On macOS 26 the layered source is `Poach.icon`. The layered icon uses a deeper cobalt tile in dark appearance. macOS renders the system icon styles from the separate pouch and background. The app uses the compiled catalog for the Dock. Xcode builds compile the source directly. For a Command Line Tools checkout, run the **Compile macOS icon** GitHub workflow, download its `poach-icon` artifact into `outputs/compiled-icon/`, then rebuild. The build checks the source digest before reusing the catalog.
