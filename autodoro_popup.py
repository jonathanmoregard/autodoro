#!/usr/bin/env python3
# autodoro_popup.py <timer_seconds> <delay_unlock_secs>
# Exit 0 = Delay, Exit 1 = Lock (timeout, dismissed, or Lock Now clicked)

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
import sys
import os

timer_secs      = int(sys.argv[1]) if len(sys.argv) > 1 else 60
unlock_secs     = int(sys.argv[2]) if len(sys.argv) > 2 else 3
script_dir      = os.path.dirname(os.path.abspath(__file__))
css_path        = os.path.join(script_dir, 'config', 'gtk-3.0', 'gtk.css')

# --- Styling ---
provider = Gtk.CssProvider()
provider.load_from_path(css_path)

screen = Gdk.Screen.get_default()
Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

# --- Dialog ---
dialog = Gtk.Dialog(title="Autodoro")
dialog.set_default_size(500, -1)
dialog.set_keep_above(True)
dialog.set_deletable(False)
dialog.set_default_response(Gtk.ResponseType.NONE)
dialog.connect("key-press-event", lambda w, e: e.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_ISO_Enter))

lock_btn  = dialog.add_button("Lock Now",  Gtk.ResponseType.CANCEL)
delay_btn = dialog.add_button("Delay 15m", Gtk.ResponseType.OK)
delay_btn.set_sensitive(False)

label = Gtk.Label()
label.set_markup(
    "<span foreground='white' font='22'><b>Time's almost up!</b></span>\n\n"
    f"<span foreground='white' font='16'>Computer will auto-lock in <b>{timer_secs} seconds</b>.</span>"
)
label.set_margin_top(24)
label.set_margin_bottom(24)
label.set_margin_start(24)
label.set_margin_end(24)
dialog.get_content_area().add(label)
dialog.show_all()
dialog.get_window().set_keep_above(True)  # re-assert after window is realized

# --- Timers ---
def enable_delay(_):
    delay_btn.set_sensitive(True)
    return False

def on_timeout(_):
    dialog.response(Gtk.ResponseType.CANCEL)
    return False

GLib.timeout_add(unlock_secs * 1000, enable_delay, None)
GLib.timeout_add(timer_secs  * 1000, on_timeout,   None)

# --- Run ---
response = dialog.run()
dialog.destroy()

sys.exit(0 if response == Gtk.ResponseType.OK else 1)
