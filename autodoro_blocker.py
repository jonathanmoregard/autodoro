#!/usr/bin/env python3
# autodoro_blocker.py [duration_secs]
# Fullscreen break overlay. Type "I NEED TO ENTER NOW" + Enter to dismiss early.
# Mutes audio while up, plays a ping and unmutes after duration_secs (default 300).

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib
import sys
import os
import subprocess

PASSPHRASE    = "I NEED TO ENTER NOW"
IMAGE_PATH    = "/home/jonathan/Repos/intender/src/public/assets/misty-1920.webp"
PING_SOUND    = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gong.mp3")
duration_secs = int(sys.argv[1]) if len(sys.argv) > 1 else 300

typed = []

# --- Audio control ---
def mute():
    subprocess.run(['pactl', 'set-sink-mute', '@DEFAULT_SINK@', '1'], capture_output=True)

def unmute():
    subprocess.run(['pactl', 'set-sink-mute', '@DEFAULT_SINK@', '0'], capture_output=True)

def on_timeout():
    unmute()
    subprocess.Popen(['paplay', PING_SOUND])
    Gtk.main_quit()
    return False

def on_early_exit():
    unmute()
    Gtk.main_quit()

mute()

# --- Screen size ---
screen = Gdk.Screen.get_default()
sw = screen.get_width()
sh = screen.get_height()

# --- CSS ---
css = b"""
.text-box {
    background-color: rgba(0, 0, 0, 0.55);
    border-radius: 12px;
    padding: 20px 36px;
}
.hint-text {
    color: white;
    font-size: 15px;
}
.typed-text {
    color: white;
    font-size: 20px;
    font-weight: bold;
}
.error-text {
    color: #ff8888;
    font-size: 20px;
    font-weight: bold;
}
"""
provider = Gtk.CssProvider()
provider.load_from_data(css)
Gtk.StyleContext.add_provider_for_screen(
    screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
)

# --- Window ---
win = Gtk.Window()
win.set_decorated(False)
win.set_keep_above(True)
win.set_skip_taskbar_hint(True)
win.set_skip_pager_hint(True)
win.set_default_size(sw, sh)

# --- Layout ---
overlay = Gtk.Overlay()
win.add(overlay)

pixbuf   = GdkPixbuf.Pixbuf.new_from_file_at_scale(IMAGE_PATH, sw, sh, False)
bg_image = Gtk.Image.new_from_pixbuf(pixbuf)
overlay.add(bg_image)

# Text box anchored to bottom center
text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
text_box.set_halign(Gtk.Align.CENTER)
text_box.set_valign(Gtk.Align.END)
text_box.set_margin_bottom(64)
text_box.get_style_context().add_class('text-box')

hint_label = Gtk.Label(label="Type  I NEED TO ENTER NOW  + Enter to return early")
hint_label.get_style_context().add_class('hint-text')

typed_label = Gtk.Label(label=" ")
typed_label.get_style_context().add_class('typed-text')

text_box.add(hint_label)
text_box.add(typed_label)
overlay.add_overlay(text_box)

win.show_all()
win.fullscreen()
win.get_window().set_keep_above(True)
win.grab_focus()

# --- Key handling ---
def update_typed():
    typed_label.get_style_context().remove_class('error-text')
    typed_label.get_style_context().add_class('typed-text')
    typed_label.set_text(''.join(typed) if typed else ' ')

def on_key_press(widget, event):
    if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
        if ''.join(typed) == PASSPHRASE:
            on_early_exit()
        else:
            typed.clear()
            typed_label.get_style_context().remove_class('typed-text')
            typed_label.get_style_context().add_class('error-text')
            typed_label.set_text('✗  incorrect — try again')
            GLib.timeout_add(1200, lambda: update_typed() or False)
        return True

    if event.keyval == Gdk.KEY_Escape:
        typed.clear()
        update_typed()
        return True

    if event.keyval == Gdk.KEY_BackSpace:
        if typed:
            typed.pop()
        update_typed()
        return True

    char = chr(event.keyval) if 32 <= event.keyval <= 126 else None
    if char:
        typed.append(char)
        if len(typed) > len(PASSPHRASE):
            typed.pop(0)
        update_typed()
    return True

win.connect("key-press-event", on_key_press)

# --- Auto-dismiss with ping ---
GLib.timeout_add_seconds(duration_secs, on_timeout)

Gtk.main()
