#!/usr/bin/env python3
# autodoro_blocker.py [--dev] [duration_secs]
# --dev: no audio mute/ping, window not forced on top (for UI iteration)

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib
import sys
import os
import subprocess

PASSPHRASE    = "I need to enter now"
IMAGE_PATH    = "/home/jonathan/Repos/intender/src/public/assets/misty-1280.webp"
PING_SOUND    = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gong.mp3")
args          = sys.argv[1:]
DEV_MODE      = '--dev' in args
args          = [a for a in args if a != '--dev']
duration_secs = int(args[0]) if args else 300

# --- Audio ---
def mute():
    subprocess.run(['pactl', 'set-sink-mute', '@DEFAULT_SINK@', '1'], capture_output=True)

def unmute():
    subprocess.run(['pactl', 'set-sink-mute', '@DEFAULT_SINK@', '0'], capture_output=True)

break_done = [False]

def on_timeout():
    if not DEV_MODE:
        subprocess.Popen(['paplay', PING_SOUND])
    break_done[0] = True
    # Swap input for an Open button
    instruction.set_markup('Break complete.')
    card.remove(entry)
    card.remove(error_label)
    open_btn = Gtk.Button(label="Open")
    open_btn.get_style_context().add_class('open-button')
    def on_open(_):
        if not DEV_MODE:
            unmute()
        Gtk.main_quit()
    open_btn.connect('clicked', on_open)
    card.add(open_btn)
    cards_box.show_all()
    open_btn.grab_focus()
    return False

def on_early_exit():
    if not DEV_MODE:
        unmute()
    Gtk.main_quit()

if not DEV_MODE:
    mute()

with open('/tmp/autodoro_blocker.pid', 'w') as f:
    f.write(str(os.getpid()))

# --- Screen ---
display = Gdk.Display.get_default()
geo     = display.get_monitor(0).get_geometry()
sw, sh  = geo.width, geo.height

# --- CSS ---
css = b"""
* { font-family: "Ubuntu Sans", "Ubuntu", "Noto Sans", sans-serif; }

.card {
    background-color: rgba(254, 249, 235, 0.92);
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.6);
    box-shadow: 0 6px 24px rgba(0, 0, 0, 0.08);
    padding: 32px 40px;
    min-width: 380px;
}
.card-instruction {
    color: rgba(48, 51, 46, 0.7);
    font-size: 20px;
    font-weight: 600;
}
entry {
    background-color: white;
    border-radius: 8px;
    border: 1px solid #ece6d1;
    color: rgba(48, 51, 46, 0.8);
    caret-color: rgba(48, 51, 46, 0.8);
    font-size: 19px;
    padding: 8px 12px;
    min-width: 400px;
}
entry:focus {
    border-color: #898e21;
    box-shadow: 0 0 0 3px rgba(137, 142, 33, 0.1);
}
.error-label {
    color: #DC5014;
    font-size: 13px;
    font-weight: 500;
}
.open-button {
    background-color: #898e21;
    border-radius: 8px;
    border: none;
    color: white;
    font-size: 19px;
    font-weight: 600;
    padding: 10px 32px;
    min-width: 400px;
}
.open-button:hover {
    background-color: #6e7219;
}
.timer-card {
    min-width: 0;
    padding: 16px 32px;
}
.timer-label {
    color: rgba(48, 51, 46, 0.9);
    font-size: 48px;
    font-weight: 700;
}
"""
provider = Gtk.CssProvider()
provider.load_from_data(css)
Gtk.StyleContext.add_provider_for_screen(
    Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
)

# --- Window ---
win = Gtk.Window()
win.set_decorated(False)
win.set_keep_above(not DEV_MODE)
win.set_skip_taskbar_hint(True)
win.set_default_size(sw, sh)

overlay = Gtk.Overlay()
win.add(overlay)

pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(IMAGE_PATH, sw, sh, False)
overlay.add(Gtk.Image.new_from_pixbuf(pixbuf))

# --- Timer card ---
remaining = [duration_secs]

timer_label = Gtk.Label()
timer_label.get_style_context().add_class('timer-label')

def fmt_time(secs):
    return f'{secs // 60}:{secs % 60:02d}'

timer_label.set_text(fmt_time(duration_secs))

timer_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
timer_card.set_halign(Gtk.Align.CENTER)
timer_card.get_style_context().add_class('card')
timer_card.get_style_context().add_class('timer-card')
timer_card.add(timer_label)

def update_countdown():
    remaining[0] -= 1
    timer_label.set_text(fmt_time(remaining[0]))
    return remaining[0] > 0

GLib.timeout_add(1000, update_countdown)

# --- Card ---
card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
card.get_style_context().add_class('card')

# Instruction with passphrase inline
instruction = Gtk.Label()
instruction.set_markup(
    'Type  <span foreground="#898e21" weight="bold">"I need to enter now"</span>  to return early.'
)
instruction.set_justify(Gtk.Justification.LEFT)
instruction.get_style_context().add_class('card-instruction')

# Proper text entry with blinking cursor
entry = Gtk.Entry()
entry.set_placeholder_text("start typing…")
entry.set_alignment(0)  # left-align text and cursor

# Error label (hidden until needed)
error_label = Gtk.Label(label="")
error_label.get_style_context().add_class('error-label')
error_label.set_halign(Gtk.Align.CENTER)

card.add(instruction)
card.add(entry)
card.add(error_label)

# Stack both cards vertically, centered on screen
cards_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
cards_box.set_halign(Gtk.Align.CENTER)
cards_box.set_valign(Gtk.Align.CENTER)
cards_box.add(timer_card)
cards_box.add(card)
overlay.add_overlay(cards_box)

win.show_all()
error_label.hide()
win.fullscreen()
if not DEV_MODE:
    win.get_window().set_keep_above(True)
entry.grab_focus()

# --- Entry handlers ---
def on_activate(widget):
    text = entry.get_text()
    if text == PASSPHRASE:
        on_early_exit()
    else:
        entry.set_text("")
        entry.get_style_context().add_class('error')
        error_label.set_text("✗  incorrect — try again")
        error_label.show()
        def clear_error():
            entry.get_style_context().remove_class('error')
            error_label.hide()
            return False
        GLib.timeout_add(1400, clear_error)

def on_key_press(widget, event):
    if break_done[0] and event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
        Gtk.main_quit()
        return True
    if event.keyval == Gdk.KEY_Escape:
        entry.set_text("")
        entry.get_style_context().remove_class('error')
        error_label.hide()
        return True
    return False

entry.connect("activate", on_activate)
win.connect("key-press-event", on_key_press)
GLib.timeout_add_seconds(duration_secs, on_timeout)
Gtk.main()
