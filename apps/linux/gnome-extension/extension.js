// Poach Capture: keeps Poach's recording controls out of its own recordings,
// and gives Poach a top bar menu and a global shortcut while it runs.
//
// Mutter records an area (org.gnome.Mutter.ScreenCast RecordArea) by painting
// the stage again into an off-screen framebuffer. The effect below lets the
// controls window paint only into the framebuffers of real stage views, so it
// stays visible on the monitor and is absent from those off-screen paints.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const CONTROLS_TITLE = 'Poach Recording';
const EFFECT_NAME = 'poach-hide-from-capture';
const MARGIN = 24;
// 2: Poach may hide its window on close because the top bar item exists.
const API_VERSION = 2;

const APP_NAME = 'io.github.poach.App';
const APP_PATH = '/io/github/poach/App';
const APP_INTERFACE = 'io.github.poach.App';
const SHORTCUT = 'toggle-recording';

/** Call a method on the running Poach; failures only mean Poach just quit. */
function callPoach(method) {
    Gio.DBus.session.call(APP_NAME, APP_PATH, APP_INTERFACE, method, null, null,
        Gio.DBusCallFlags.NONE, -1, null, null);
}

const DBUS_PATH = '/io/github/poach/Shell';
const DBUS_INTERFACE = `
<node>
  <interface name="io.github.poach.Shell">
    <method name="GetVersion">
      <arg type="u" direction="out" name="version"/>
    </method>
    <method name="GetCaptureMonitor">
      <arg type="i" direction="out" name="x"/>
      <arg type="i" direction="out" name="y"/>
      <arg type="i" direction="out" name="width"/>
      <arg type="i" direction="out" name="height"/>
    </method>
  </interface>
</node>`;

const HideFromCaptureEffect = GObject.registerClass(
class PoachHideFromCaptureEffect extends Clutter.Effect {
    vfunc_paint(node, paintContext, flags) {
        if (this._paintsOnScreen(paintContext))
            super.vfunc_paint(node, paintContext, flags);
    }

    _paintsOnScreen(paintContext) {
        const framebuffer = paintContext.get_framebuffer();
        return this.actor.peek_stage_views().some(view =>
            view.get_framebuffer() === framebuffer || view.get_onscreen() === framebuffer);
    }
});

/** Methods Poach calls over D-Bus. */
class PoachShellService {
    GetVersion() {
        return API_VERSION;
    }

    /** The monitor under the pointer, in stage coordinates (as RecordArea expects). */
    GetCaptureMonitor() {
        const rect = global.display.get_monitor_geometry(global.display.get_current_monitor());
        return [rect.x, rect.y, rect.width, rect.height];
    }
}

/** Poach's top bar item, the counterpart of the macOS menu bar pouch. */
const PoachIndicator = GObject.registerClass(
class PoachIndicator extends PanelMenu.Button {
    _init(iconPath) {
        super._init(0.5, 'Poach');
        this._icon = new St.Icon({gicon: Gio.icon_new_for_string(iconPath), style_class: 'system-status-icon'});
        this.add_child(this._icon);

        const item = (label, method) => {
            const menuItem = new PopupMenu.PopupMenuItem(label);
            menuItem.connect('activate', () => callPoach(method));
            this.menu.addMenuItem(menuItem);
            return menuItem;
        };
        item('Open Poach', 'Open');
        item('New Screenshot', 'NewScreenshot');
        this._recordItem = item('New Recording', 'NewRecording');
        this._stopItem = item('Stop Recording', 'ToggleRecording');
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        item('Quit Poach', 'Quit');
        this.setRecording(false);
    }

    setRecording(recording) {
        this._recordItem.visible = !recording;
        this._stopItem.visible = recording;
        // Lime, like the dot in the recording controls.
        this._icon.style = recording ? 'color: #e5f765;' : null;
        this.accessible_name = recording ? 'Poach, recording' : 'Poach';
    }
});

export default class PoachCaptureExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._appWatch = Gio.bus_watch_name(Gio.BusType.SESSION, APP_NAME, Gio.BusNameWatcherFlags.NONE,
            () => this._poachStarted(), () => this._poachStopped());
        this._windowSignals = new Map();
        this._service = Gio.DBusExportedObject.wrapJSObject(DBUS_INTERFACE, new PoachShellService());
        this._service.export(Gio.DBus.session, DBUS_PATH);
        this._createdId = global.display.connect('window-created', (_display, window) => this._watch(window));
        for (const actor of global.get_window_actors())
            this._watch(actor.get_meta_window());
    }

    disable() {
        Gio.bus_unwatch_name(this._appWatch);
        this._poachStopped();
        this._settings = null;
        global.display.disconnect(this._createdId);
        for (const [window, ids] of this._windowSignals) {
            ids.forEach(id => window.disconnect(id));
            window.get_compositor_private()?.remove_effect_by_name(EFFECT_NAME);
        }
        this._windowSignals = null;
        this._service.unexport();
        this._service = null;
    }

    /** Poach is running: show its item and enable the shortcut. */
    _poachStarted() {
        if (this._indicator)
            return;
        this._indicator = new PoachIndicator(this.dir.get_child('icons/poach-symbolic.svg').get_path());
        Main.panel.addToStatusArea(this.uuid, this._indicator);
        this._propertiesId = Gio.DBus.session.signal_subscribe(APP_NAME, 'org.freedesktop.DBus.Properties',
            'PropertiesChanged', APP_PATH, null, Gio.DBusSignalFlags.NONE,
            (_connection, _sender, _path, _iface, _signal, parameters) => {
                const recording = parameters.deepUnpack()[1]['Recording'];
                if (recording)
                    this._indicator?.setRecording(recording.unpack());
            });
        Gio.DBus.session.call(APP_NAME, APP_PATH, 'org.freedesktop.DBus.Properties', 'Get',
            new GLib.Variant('(ss)', [APP_INTERFACE, 'Recording']), null, Gio.DBusCallFlags.NONE, -1, null,
            (connection, result) => {
                try {
                    this._indicator?.setRecording(connection.call_finish(result).deepUnpack()[0].unpack());
                } catch {
                    // Older Poach without the property: leave the idle state.
                }
            });
        Main.wm.addKeybinding(SHORTCUT, this._settings, Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, () => callPoach('ToggleRecording'));
    }

    /** Poach quit: remove its item and free the shortcut for other apps. */
    _poachStopped() {
        if (!this._indicator)
            return;
        Main.wm.removeKeybinding(SHORTCUT);
        Gio.DBus.session.signal_unsubscribe(this._propertiesId);
        this._indicator.destroy();
        this._indicator = null;
    }

    _watch(window) {
        if (!window || this._windowSignals.has(window))
            return;
        const ids = [
            window.connect('notify::title', () => this._adopt(window)),
            window.connect('shown', () => this._adopt(window)),
            window.connect('unmanaged', () => this._windowSignals?.delete(window)),
        ];
        this._windowSignals.set(window, ids);
        this._adopt(window);
    }

    _adopt(window) {
        const actor = window.get_compositor_private();
        if (!actor || window.get_title() !== CONTROLS_TITLE || actor.get_effect(EFFECT_NAME))
            return;
        actor.add_effect_with_name(EFFECT_NAME, new HideFromCaptureEffect());
        window.make_above();
        window.stick();
        // Wait for the first frame so the frame rect has its final size.
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            const area = window.get_work_area_current_monitor();
            const frame = window.get_frame_rect();
            window.move_frame(true, area.x + area.width - frame.width - MARGIN, area.y + MARGIN);
            return GLib.SOURCE_REMOVE;
        });
    }
}
