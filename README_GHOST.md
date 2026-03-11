# 👻 GHOST MINDS: Setup & Run Guide

**STATUS:** PRE-ALPHA CODE READY
**ARCHITECT:** Antigravity SPAP v2.2

## 1. 🛠️ Build Your Ghost
Since I cannot generate the binary `.xcodeproj` file directly, you must perform this **One-Time Setup**:

1.  **Open Xcode.**
2.  **Create New Project** -> **macOS Application** -> **App**.
3.  **Product Name:** `GhostMinds`
4.  **Interface:** `SwiftUI`
5.  **Language:** `Swift`
6.  **SAVE** the project into: `/Users/dogan/Desktop/new-project/` (Overwrite if needed, or just use the folder).

### 2. 📂 Import the Intelligence
Once the project is created:
1.  **Delete** the default `ContentView.swift` and `GhostMindsApp.swift` created by Xcode.
2.  **Drag & Drop** the `GhostMinds/Sources` folder into your Xcode Project Navigator.
    *   *Make sure "Copy items if needed" is unchecked.*
    *   *Make sure "Create groups" is selected.*
    *   *Check "GhostMinds" target.*
3.  **Replace Info.plist:**
    *   Open `GhostMinds/Resources/Info.plist`.
    *   Copy key items (LSUIElement, Privacy strings) into your project's main target **Info** settings OR replace the file.

### 3. ⚙️ Critical Settings (In Xcode)
To make the "Ghost" work:
*   **Signing & Capabilities:**
    *   Add **"Hardened Runtime"** (Default).
    *   Add **"App Sandbox"**: You might need to **DISABLE** App Sandbox for `CGWindowListCreateImage` to work freely, OR enable "User Selected File Read/Write" and "File Access".
    *   *Recommendation for Local Agent:* **Remove App Sandbox** entirely for full system access (Invisibility & Screen Recording).

### 4. 🚀 Launch Protocol
1.  **Run Ollama:**
    ```bash
    ollama serve
    ```
2.  **Run the App (Cmd+R)** in Xcode.
3.  **Grant Permissions:** macOS will ask for "Screen Recording" permission. **ALLOW IT.**
4.  **The Ghost Awakes:** Check your Menu Bar for the "Eye" icon. Click "Show Overlay" or use the App.

## 5. 🧠 The "Trust" Protocol (Models)
I have configured `OllamaService.swift` to use **`gpt-oss:120b-cloud`** by default as per your instructions.
To change this, edit `GhostMinds/Sources/Services/OllamaService.swift`.

## 6. 🕵️‍♀️ Testing Invisibility
1.  Open **Zoom** -> **New Meeting** -> **Share Screen** -> **Desktop 1**.
2.  Open **GhostMinds** Overlay.
3.  **Verify:** You see the Overlay. The Zoom participants **DO NOT**.
