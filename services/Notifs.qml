pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components.misc
import qs.services
import qs.utils

Singleton {
    id: root

    property list<NotifData> list: []
    readonly property list<NotifData> notClosed: list.filter(n => !n.closed)
    readonly property list<NotifData> popups: list.filter(n => n.popup)
    property alias dnd: props.dnd

    property bool loaded

    // Bounds on the notification history. Every NotifData is a live object with
    // its own timers, and every sidebar group re-filters the whole list on each
    // change, so an unbounded history turns a burst of notifications into
    // quadratic churn that leaves the dock's layout half-animated and garbled.
    readonly property int maxPerApp: 50
    readonly property int maxTotal: 300
    readonly property int maxPopups: 5

    // Notifications received since the last flush; merged into `list` in one
    // assignment so a flood costs one model update instead of one per message.
    property var pending: []

    // Returns `notifs` (newest first) with the history bounds applied. Evicted
    // notifications are dismissed and destroyed; ones a delegate still holds are
    // closed instead, and drop out of the list once their exit animation ends.
    function applyLimits(notifs: var): var {
        const perApp = new Map();
        const kept = [];
        const evicted = [];
        let open = 0;
        let popups = 0;

        for (const n of notifs) {
            if (n.closed) {
                if (n.locks.size > 0)
                    kept.push(n);
                else
                    evicted.push(n);
                continue;
            }

            const appCount = (perApp.get(n.appName) ?? 0) + 1;
            perApp.set(n.appName, appCount);

            if (appCount > maxPerApp || open >= maxTotal) {
                if (n.locks.size > 0) {
                    n.closed = true;
                    kept.push(n);
                } else {
                    evicted.push(n);
                }
                continue;
            }

            if (n.popup && ++popups > maxPopups)
                n.popup = false;

            open++;
            kept.push(n);
        }

        Qt.callLater(() => {
            for (const n of evicted) {
                n.closed = true;
                n.notification?.dismiss();
                n.destroy();
            }
        });

        return kept;
    }

    function flush(): void {
        if (pending.length === 0)
            return;

        const incoming = pending.reverse();
        pending = [];
        list = applyLimits([...incoming, ...list]);
    }

    function hasFullscreen(): bool {
        for (const monitor of Hypr.monitors.values) {
            if (monitor?.activeWorkspace?.toplevels.values.some(t => t.lastIpcObject.fullscreen > 1))
                return true;
        }
        return false;
    }

    function shouldShowPopup(): bool {
        if (props.dnd || ShellState.anySidebarOpen())
            return false;
        if (GlobalConfig.notifs.fullscreen === NotifsFullscreen.Off && hasFullscreen())
            return false;
        return true;
    }

    onDndChanged: {
        if (!GlobalConfig.utilities.toasts.dndChanged)
            return;

        if (dnd)
            Toaster.toast(Tr.tr("Do not disturb enabled"), Tr.tr("Popup notifications are now disabled"), "do_not_disturb_on");
        else
            Toaster.toast(Tr.tr("Do not disturb disabled"), Tr.tr("Popup notifications are now enabled"), "do_not_disturb_off");
    }

    onListChanged: {
        if (loaded)
            saveTimer.restart();
    }

    Timer {
        id: saveTimer

        interval: 1000
        onTriggered: storage.setText(JSON.stringify(root.notClosed.map(n => ({
                    time: n.time,
                    id: n.id,
                    summary: n.summary,
                    body: n.body,
                    appIcon: n.appIcon,
                    appName: n.appName,
                    image: n.image,
                    expireTimeout: n.expireTimeout,
                    urgency: n.urgency,
                    resident: n.resident,
                    hasActionIcons: n.hasActionIcons,
                    actions: n.actions
                }))))
    }

    PersistentProperties {
        id: props

        property bool dnd

        reloadableId: "notifs"
    }

    NotificationServer {
        id: server

        keepOnReload: false
        actionsSupported: true
        bodyHyperlinksSupported: true
        bodyImagesSupported: true
        bodyMarkupSupported: true
        imageSupported: true
        persistenceSupported: true

        onNotification: notif => {
            notif.tracked = true;

            const comp = notifComp.createObject(root, {
                popup: root.shouldShowPopup(),
                notification: notif
            });
            root.pending.push(comp);
            if (!flushTimer.running)
                flushTimer.start();
        }
    }

    Timer {
        id: flushTimer

        interval: 50
        onTriggered: root.flush()
    }

    FileView {
        id: storage

        printErrors: false
        path: `${Paths.state}/notifs.json`
        onLoaded: {
            const data = JSON.parse(text());
            for (const notif of data) {
                const properties = Object.assign({}, notif);

                // Backwards compatibility for old notifications
                if (properties.notificationId === undefined && properties.id !== undefined)
                    properties.notificationId = properties.id;

                delete properties.id;
                root.list.push(notifComp.createObject(root, properties));
            }
            root.list.sort((a, b) => b.time - a.time);
            root.loaded = true;
            root.list = root.applyLimits(root.list);
        }
        onLoadFailed: err => {
            if (err === FileViewError.FileNotFound) {
                root.loaded = true;
                Qt.callLater(() => setText("[]"));
            }
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "clearNotifs"
        description: "Clear all notifications"
        onPressed: {
            root.flush();
            for (const notif of root.list.slice())
                notif.close();
        }
    }

    IpcHandler {
        function clear(): void {
            root.flush();
            for (const notif of root.list.slice())
                notif.close();
        }

        function isDndEnabled(): bool {
            return props.dnd;
        }

        function toggleDnd(): void {
            props.dnd = !props.dnd;
        }

        function enableDnd(): void {
            props.dnd = true;
        }

        function disableDnd(): void {
            props.dnd = false;
        }

        target: "notifs"
    }

    Component {
        id: notifComp

        NotifData {}
    }
}
