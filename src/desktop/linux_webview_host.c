#include <glib.h>
#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>
#include <gdk/gdkkeysyms.h>
#include <webkit2/webkit2.h>

#include "linux_webview_host_support.h"

static void on_destroy(GtkWidget *widget, gpointer data) {
    (void)widget;
    (void)data;
    gtk_main_quit();
}


static void set_qa_state(AppState *state, const char *heading, const char *text, const char *controller_stdout) {
    char *markup = g_markup_printf_escaped(
        "<span foreground='#d6ecff' size='x-large' weight='bold'>%s</span>\n"
        "<span foreground='#34c8e8'>%s</span>\n"
        "<span foreground='#b8f7d4'>controller_event_history verified; source=zig-controller</span>",
        heading,
        text);
    gtk_label_set_markup(state->label, markup);
    g_free(markup);
    char *title = g_strdup_printf("zig-scheduler · live microVM lab · controller_event_history · %s", text);
    gtk_window_set_title(state->window, title);
    g_free(title);
    append_log_line(state, "window-state.jsonl", heading, text);
    if (controller_stdout != NULL && controller_stdout[0] != '\0') {
        append_log_line(state, "window-state.jsonl", "controller_stdout", controller_stdout);
    }
}


static int bridge_method_allowed(const char *method) {
    return strcmp(method, "status") == 0 ||
        strcmp(method, "run") == 0 ||
        strcmp(method, "rollback") == 0 ||
        strcmp(method, "stop") == 0 ||
        strcmp(method, "subscribe") == 0;
}

static void run_controller_bridge(AppState *state, const char *method) {
    gchar *stdout_text = NULL;
    gchar *stderr_text = NULL;
    gint exit_status = 0;
    const gchar *argv[] = {
        state->app_path,
        "--state-dir",
        state->state_dir,
        "--fake-daemon",
        state->daemon_path,
        "--bridge-test",
        method,
        NULL,
    };
    gboolean ok = g_spawn_sync(NULL, (gchar **)argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, &stdout_text, &stderr_text, &exit_status, NULL);
    if (!ok || exit_status != 0) {
        const char *detail = stderr_text != NULL ? stderr_text : "bridge spawn failed";
        set_qa_state(state, "controller bridge incident", "qa_state=incident controller_status=incident source=zig-controller host_mutation=false production_ready=false FAIL-CLOSED", detail);
        g_free(stdout_text);
        g_free(stderr_text);
        return;
    }
    append_controller_events(state, stdout_text);
    if (stdout_contains(stdout_text, "stop_lab_run") || stdout_contains(stdout_text, "desktop-stop-")) {
        set_qa_state(state, "stopped live microVM run", "qa_state=stopped cause=stop_action controller_status=accepted controller_source=event_history action=stop_lab_run desktop-stop-dispatched host_mutation=false production_ready=false FAIL-CLOSED", stdout_text);
    } else if (stdout_contains(stdout_text, "duplicate_action_id")) {
        set_qa_state(state, "REFUSE duplicate action id", "qa_state=duplicate_refusal cause=duplicate_run_action controller_status=refused reason=duplicate_action_id controller_source=event_history host_mutation=false production_ready=false FAIL-CLOSED", stdout_text);
    } else if (stdout_contains(stdout_text, "stale_or_unknown_target_action_id")) {
        set_qa_state(state, "REFUSE stale target action id", "qa_state=stale_refusal cause=stale_rollback_action controller_status=refused reason=stale_or_unknown_target_action_id controller_source=event_history host_mutation=false production_ready=false FAIL-CLOSED", stdout_text);
    } else if (stdout_contains(stdout_text, "controller_status=accepted") || stdout_contains(stdout_text, "\"status\":\"PASS\"")) {
        set_qa_state(state, "accepted live microVM run", "qa_state=running cause=run_action controller_status=accepted controller_source=event_history daemon event stream host_mutation=false production_ready=false FAIL-CLOSED", stdout_text);
    } else {
        set_qa_state(state, "controller bridge completed", "qa_state=controller_result controller_source=event_history host_mutation=false production_ready=false FAIL-CLOSED", stdout_text);
    }
    g_free(stdout_text);
    g_free(stderr_text);
}

static gboolean on_key_press(GtkWidget *widget, GdkEventKey *event, gpointer data) {
    (void)widget;
    AppState *state = (AppState *)data;
    if (event->keyval == GDK_KEY_m || event->keyval == GDK_KEY_M) {
        state->run_count += 1;
        run_controller_bridge(state, state->run_count == 1 ? "gui-run" : "gui-duplicate-run");
        return FALSE;
    }
    if (event->keyval == GDK_KEY_b || event->keyval == GDK_KEY_B) {
        run_controller_bridge(state, "gui-stale-rollback");
        return FALSE;
    }
    if (event->keyval == GDK_KEY_s || event->keyval == GDK_KEY_S) {
        run_controller_bridge(state, "gui-stop");
        return FALSE;
    }
    if (event->keyval == GDK_KEY_w || event->keyval == GDK_KEY_W) {
        set_qa_state(state, "theme key observed", "qa_state=theme_key window_action=theme_toggle source=target_window_rendered_layer host_mutation=false production_ready=false FAIL-CLOSED", "");
    }
    if (event->keyval == GDK_KEY_question || event->keyval == GDK_KEY_slash) {
        set_qa_state(state, "help key observed", "qa_state=help_key window_action=help_overlay source=target_window_rendered_layer host_mutation=false production_ready=false FAIL-CLOSED", "");
    }
    return FALSE;
}

static char *bridge_message_to_string(WebKitJavascriptResult *message) {
    JSCValue *value = webkit_javascript_result_get_js_value(message);
    if (value == NULL) return NULL;
    return jsc_value_to_string(value);
}

static void on_bridge_script_message(WebKitUserContentManager *manager, WebKitJavascriptResult *message, gpointer data) {
    (void)manager;
    AppState *state = (AppState *)data;
    char *method = bridge_message_to_string(message);
    if (method == NULL || method[0] == '\0') {
        set_qa_state(state, "REFUSE unsupported bridge method", "qa_state=bridge_refusal reason=empty_bridge_method bridge_mode=webkitgtk-script-message host_mutation=false production_ready=false FAIL-CLOSED", "");
        g_free(method);
        return;
    }
    append_log_line(state, "dom-debug.jsonl", "webkitgtk-script-message", method);
    if (!bridge_method_allowed(method)) {
        set_qa_state(state, "REFUSE unsupported bridge method", "qa_state=bridge_refusal reason=unsupported_bridge_method bridge_mode=webkitgtk-script-message host_mutation=false production_ready=false FAIL-CLOSED", method);
    } else if (strcmp(method, "status") == 0) {
        set_qa_state(state, "desktop controller bridge status", "qa_state=status bridge_mode=webkitgtk-script-message controller_source=event_history host_mutation=false production_ready=false FAIL-CLOSED", method);
    } else if (strcmp(method, "subscribe") == 0) {
        set_qa_state(state, "desktop controller bridge subscribed", "qa_state=subscribed bridge_mode=webkitgtk-script-message controller_source=event_history host_mutation=false production_ready=false FAIL-CLOSED", method);
    } else if (strcmp(method, "run") == 0) {
        state->run_count += 1;
        run_controller_bridge(state, state->run_count == 1 ? "gui-run" : "gui-duplicate-run");
    } else if (strcmp(method, "rollback") == 0) {
        run_controller_bridge(state, "gui-stale-rollback");
    } else if (strcmp(method, "stop") == 0) {
        run_controller_bridge(state, "gui-stop");
    }
    g_free(method);
}

static void on_title_changed(WebKitWebView *webview, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    GtkWindow *window = GTK_WINDOW(data);
    const gchar *title = webkit_web_view_get_title(webview);
    if (title != NULL && title[0] != '\0') {
        gtk_window_set_title(window, title);
    }
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: zig-scheduler-live-vm-webview-host <title> <html-file> <app-path> <state-dir> <daemon-path>\n");
        return 64;
    }

    if (!state_dir_has_no_symlink_components(argv[4])) {
        fprintf(stderr, "REFUSE system WebView state_dir invalid before write: InvalidStateDir host_mutation=false production_ready=false\n");
        return 7;
    }

    if (!gtk_init_check(&argc, &argv)) {
        fprintf(stderr, "SKIP system WebView runtime unavailable: gtk_init_check_failed; host_mutation=false\n");
        return 3;
    }

    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    if (window == NULL) {
        fprintf(stderr, "SKIP system WebView runtime unavailable: gtk_window_new_failed; host_mutation=false\n");
        return 5;
    }
    WebKitUserContentManager *content_manager = webkit_user_content_manager_new();
    if (content_manager == NULL) {
        gtk_widget_destroy(window);
        fprintf(stderr, "SKIP system WebView runtime unavailable: user_content_manager_new_failed; host_mutation=false\n");
        return 6;
    }
    if (!webkit_user_content_manager_register_script_message_handler(content_manager, "zigSchedulerDesktopBridge")) {
        g_object_unref(content_manager);
        gtk_widget_destroy(window);
        fprintf(stderr, "SKIP system WebView runtime unavailable: bridge_handler_register_failed; host_mutation=false\n");
        return 6;
    }
    WebKitUserScript *bridge_script = webkit_user_script_new(
        bridge_injection_script,
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        NULL,
        NULL);
    webkit_user_content_manager_add_script(content_manager, bridge_script);
    webkit_user_script_unref(bridge_script);
    GtkWidget *webview = webkit_web_view_new_with_user_content_manager(content_manager);
    if (webview == NULL) {
        g_object_unref(content_manager);
        gtk_widget_destroy(window);
        fprintf(stderr, "SKIP system WebView runtime unavailable: webkit_web_view_new_failed; host_mutation=false\n");
        return 6;
    }

    gtk_window_set_title(GTK_WINDOW(window), argv[1]);
    gtk_window_set_default_size(GTK_WINDOW(window), 1180, 820);
    gtk_window_set_position(GTK_WINDOW(window), GTK_WIN_POS_CENTER);
    GtkWidget *overlay = gtk_overlay_new();
    GtkWidget *qa_label = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(qa_label), 0.0);
    gtk_label_set_yalign(GTK_LABEL(qa_label), 0.0);
    gtk_widget_set_halign(qa_label, GTK_ALIGN_START);
    gtk_widget_set_valign(qa_label, GTK_ALIGN_END);
    gtk_widget_set_margin_bottom(qa_label, 24);
    gtk_widget_set_margin_start(qa_label, 24);
    gtk_widget_set_margin_end(qa_label, 24);
    gtk_container_add(GTK_CONTAINER(overlay), webview);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), qa_label);
    gtk_container_add(GTK_CONTAINER(window), overlay);
    AppState state = { GTK_WINDOW(window), GTK_LABEL(qa_label), WEBKIT_WEB_VIEW(webview), argv[3], argv[4], argv[5], 0 };
    if (!state_dir_has_no_symlink_components(state.state_dir)) {
        gtk_widget_destroy(window);
        fprintf(stderr, "REFUSE system WebView state_dir invalid before write: InvalidStateDir host_mutation=false production_ready=false\n");
        return 7;
    }
    if (g_mkdir_with_parents(state.state_dir, 0700) != 0 || !state_dir_has_no_symlink_components(state.state_dir)) {
        gtk_widget_destroy(window);
        fprintf(stderr, "REFUSE system WebView state_dir invalid before write: InvalidStateDir host_mutation=false production_ready=false\n");
        return 7;
    }
    char *events_path = state_path(&state, "events.jsonl");
    char *window_state_path = state_path(&state, "window-state.jsonl");
    if (path_is_symlink(events_path) || path_is_symlink(window_state_path)) {
        g_free(events_path);
        g_free(window_state_path);
        gtk_widget_destroy(window);
        fprintf(stderr, "REFUSE system WebView state file symlink before write: InvalidStateDir host_mutation=false production_ready=false\n");
        return 7;
    }
    g_unlink(events_path);
    g_unlink(window_state_path);
    g_free(events_path);
    g_free(window_state_path);
    set_qa_state(&state, "desktop controller bridge ready", "qa_state=hero bridge_mode=webkitgtk-script-message controller_source=awaiting_gui_action visible=live microVM lab daemon event stream host_mutation=false production_ready=false FAIL-CLOSED", "");
    g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), NULL);
    g_signal_connect(window, "key-press-event", G_CALLBACK(on_key_press), &state);
    g_signal_connect(webview, "notify::title", G_CALLBACK(on_title_changed), window);
    g_signal_connect(content_manager, "script-message-received::zigSchedulerDesktopBridge", G_CALLBACK(on_bridge_script_message), &state);
    g_object_unref(content_manager);
    GError *uri_error = NULL;
    char *absolute_html_path = g_canonicalize_filename(argv[2], NULL);
    char *uri = g_filename_to_uri(absolute_html_path, NULL, &uri_error);
    g_free(absolute_html_path);
    if (uri == NULL) {
        if (uri_error != NULL) {
            fprintf(stderr, "SKIP system WebView runtime unavailable: html_uri_failed:%s; host_mutation=false\n", uri_error->message);
            g_error_free(uri_error);
        }
        gtk_widget_destroy(window);
        return 7;
    }
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview), uri);
    g_free(uri);
    gtk_widget_show_all(window);
    gtk_main();
    return 0;
}
