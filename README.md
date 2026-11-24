# Grossify Desktop

Grossify is a local grocery store management and point-of-sale app for macOS. It has a native SwiftUI desktop interface, a C++17 backend, and a SQLite database stored on the same Mac. The backend is not hosted on the internet; it must be running on the same Mac as the app.

## What you need

- A Mac running macOS 13 (Ventura) or later.
- Apple Xcode Command Line Tools, which provide Swift, `clang++`, and the macOS SDK. A full Xcode installation is not required.
- An internet connection to clone the repository the first time.
- SQLite is included with macOS and the Command Line Tools. The backend links to it with `-lsqlite3`; no separate SQLite download is normally needed.

To install the Command Line Tools, open Terminal (Applications → Utilities → Terminal) and run:

```bash
xcode-select --install
```

Follow the macOS installation prompt. Check that the tools are available:

```bash
xcode-select -p
swift --version
clang++ --version
```

## Download the project

The commands below clone the GitHub repository into a folder named `Grossify_Desktop` inside your Downloads folder. They do not depend on your Mac account name.

```bash
cd "$HOME/Downloads"
git clone https://github.com/pdeshaya/Grossify.git Grossify_Desktop
cd "$HOME/Downloads/Grossify_Desktop"
pwd
```

The final command should print a path ending in `/Downloads/Grossify_Desktop`. If you already downloaded or cloned the project, use `cd "$HOME/Downloads/Grossify_Desktop"` to enter it. Keep the Terminal window open for the backend.

## Run Grossify

### 1. Start the backend

From the project folder, start the backend using the included helper:

```bash
./Scripts/start_backend.command
```

The helper finds the project folder from its own location, builds the C++ backend with the SQLite linker flag, then runs it from `Backend` so the database is created or opened at `Backend/grossify.db`. The first run may take a few seconds to compile. A successful start reports that the server is listening on port `8080`. Leave this Terminal window open while using the app.

If macOS says the script is not executable, run it through Bash instead:

```bash
bash Scripts/start_backend.command
```

You can also build and start the backend manually from the project folder:

```bash
cd "$HOME/Downloads/Grossify_Desktop/Backend"
clang++ -std=c++17 -Wall -Wextra grossify_backend.cpp -lsqlite3 -o grossify_backend
./grossify_backend 8080
```

### 2. Launch the desktop app

Open a second Terminal window (Terminal menu → Shell → New Window). Enter the project folder and run the Swift app:

```bash
cd "$HOME/Downloads/Grossify_Desktop"
swift run GrossifyDesktop
```

Swift Package Manager builds the app the first time, then opens the Grossify window. The app connects to the backend at `http://127.0.0.1:8080`. Keep both Terminal windows open while using Grossify.

### 3. Stop the app

Quit Grossify with **Grossify → Quit Grossify** or press `Command-Q`. In the backend Terminal window, press `Control-C` to stop the server.

## What to expect

Grossify runs entirely on this Mac. The dashboard should show that the backend is connected. Products, inventory changes, and bills are stored in the local `Backend/grossify.db` database. That database is created automatically on the first backend run and is ignored by Git. There is no hosted web demo or Windows version in this setup.

## Troubleshooting

- **`cd: ... No such file or directory`**: Run the clone commands above first. If the folder was saved elsewhere, change the `cd` path to that actual location. To avoid typing the path, type `cd ` (including the space), drag the `Grossify_Desktop` folder from Finder into Terminal, then press Return.
- **`xcode-select: error: command line tools are not installed`**: Run `xcode-select --install`, complete the installation, then reopen Terminal.
- **`clang++: command not found` or `swift: command not found`**: Install the Command Line Tools and verify with `xcode-select -p`.
- **SQLite header or linker error**: Confirm the Command Line Tools installation is complete. The build uses the macOS SQLite library via `-lsqlite3`; no Homebrew package is expected.
- **`Address already in use` / port 8080 is busy**: Stop any other Grossify backend with `Control-C` in its Terminal window, then start it again. The app is configured to use port `8080`.
- **App shows backend offline**: Make sure the backend Terminal says it is listening on port `8080`, and leave it running. Start the backend before launching the app.
- **`swift run` cannot find the package**: In that Terminal window, run `cd "$HOME/Downloads/Grossify_Desktop"` before `swift run GrossifyDesktop`.
- **Build errors after an update**: From the project folder, run `swift package clean`, then retry `swift run GrossifyDesktop`. This removes generated build files only; it does not remove the database.

## Project layout

```text
Grossify_Desktop/
├── Package.swift
├── README.md
├── Scripts/
│   └── start_backend.command
├── Backend/
│   └── grossify_backend.cpp
└── Sources/
    └── GrossifyDesktop/
        └── GrossifyDesktopApp.swift
```

## API endpoints

The local backend listens on `127.0.0.1:8080` and provides these endpoints:

| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/api/health` | Check backend and database health |
| `GET` | `/api/products` | List products and stock |
| `POST` | `/api/products` | Add a product |
| `POST` | `/api/inventory/adjust` | Adjust stock |
| `POST` | `/api/checkout` | Complete a sale |
| `GET` | `/api/bills` | List bills |
| `GET` | `/api/bills/details?id=<id>` | Get a bill's itemized details |
| `POST` | `/api/sync` | Submit synchronization events |
