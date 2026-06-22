#ifndef ZIG_SCHEDULER_LINUX_WEBVIEW_HOST_SUPPORT_H
#define ZIG_SCHEDULER_LINUX_WEBVIEW_HOST_SUPPORT_H

#include <glib.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

typedef struct {
    GtkWindow *window;
    GtkLabel *label;
    WebKitWebView *webview;
    const char *app_path;
    const char *state_dir;
    const char *daemon_path;
    guint run_count;
} AppState;

extern const char *bridge_injection_script;
char *state_path(AppState *state, const char *name);
int state_dir_has_no_symlink_components(const char *path);
int path_is_symlink(const char *path);
void append_log_line(AppState *state, const char *name, const char *tag, const char *text);
void append_controller_events(AppState *state, const char *stdout_text);
gboolean stdout_contains(const char *stdout_text, const char *needle);

#endif
