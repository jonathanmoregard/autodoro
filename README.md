# Force Pomodoro

A systemd user service that enforces automatic computer locking after a set work period, with intelligent meeting detection to pause the timer when your microphone is active.

## Features

- **Automatic timer**: Counts down from 25 minutes (configurable) and locks your computer when time expires
- **Meeting detection**: Automatically pauses the timer when your microphone is in use (detects active recording streams via PulseAudio/PipeWire)
- **Post-meeting grace period**: After a meeting ends, provides a 15-minute grace period before resuming the countdown
- **Warning popup**: Shows a 60-second warning before locking, with options to delay or lock immediately
- **Auto-start**: Runs automatically on login via systemd user service

## Requirements

- Linux with systemd
- PulseAudio or PipeWire (for microphone detection)
- `zenity` (for GUI popups)
- `loginctl` (for session locking)
- `pactl` (PulseAudio control, usually included with PulseAudio)

## Installation

1. Clone or download this repository:
   ```bash
   git clone <repository-url>
   cd force-pomodoro
   ```

2. Make the script executable:
   ```bash
   chmod +x force-pomodoro.sh
   ```

3. Copy the systemd service file to your user config:
   ```bash
   mkdir -p ~/.config/systemd/user
   cp force-pomodoro.service ~/.config/systemd/user/
   ```

4. Update the script path in the service file if needed:
   ```bash
   nano ~/.config/systemd/user/force-pomodoro.service
   ```
   Update the `ExecStart` line to point to the full path of your `force-pomodoro.sh` script. The default assumes `~/Repos/force-pomodoro/force-pomodoro.sh`.

5. Reload systemd and enable the service:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable force-pomodoro.service
   systemctl --user start force-pomodoro.service
   ```

The service will now start automatically on login.

## Configuration

Edit `force-pomodoro.sh` to customize:

- `WORK_TIME`: Initial timer duration in seconds (default: 1500 = 25 minutes)
- `POST_MEETING_TIME`: Grace period after meetings in seconds (default: 900 = 15 minutes)
- `WARNING_THRESHOLD`: When to show warning popup in seconds (default: 60 = 1 minute)
- `CHECK_INTERVAL`: How often to check state in seconds (default: 5)

The delay button resets the timer to 24 minutes (1440 seconds) by default.

## Usage

Once enabled, the service runs automatically in the background. You don't need to do anything - it will:

1. Start counting down from 25 minutes when you log in
2. Pause automatically when it detects your microphone is in use (meeting)
3. Resume with a 15-minute grace period after the meeting ends
4. Show a warning popup 60 seconds before locking
5. Lock your session if you don't respond or choose to lock

### Manual Control

- **Check status**: `systemctl --user status force-pomodoro.service`
- **View logs**: `journalctl --user -u force-pomodoro.service -f`
- **Restart service**: `systemctl --user restart force-pomodoro.service`
- **Stop service**: `systemctl --user stop force-pomodoro.service`
- **Disable auto-start**: `systemctl --user disable force-pomodoro.service`

## How It Works

The script continuously monitors:
1. **Microphone activity**: Uses `pactl list short source-outputs` to detect active recording streams
2. **Timer countdown**: Decrements every 5 seconds when not in a meeting
3. **Warning threshold**: Triggers a zenity popup when timer reaches 60 seconds
4. **User response**: Handles delay requests or immediate lock commands

## Troubleshooting

### Popup doesn't appear

- Check that `DISPLAY` and `XAUTHORITY` are set in the service file (should be automatic)
- Verify zenity is installed: `which zenity`
- Check logs: `journalctl --user -u force-pomodoro.service`

### Timer not pausing during meetings

- Verify PulseAudio/PipeWire is running: `pactl info`
- Check if microphone streams are detected: `pactl list short source-outputs`

### Service doesn't start on login

- Verify it's enabled: `systemctl --user is-enabled force-pomodoro.service`
- Check if `graphical-session.target` is available on your system

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

This project was developed with the assistance of Cursor, an AI-powered code editor.

