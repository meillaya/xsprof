#include "linux_webview_host_support.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

const char *bridge_injection_script =
    "(function(){"
    "  'use strict';"
    "  var methods=['status','run','rollback','stop','subscribe'];"
    "  function allowed(method){return methods.indexOf(method)!==-1;}"
    "  function post(method){"
    "    if(!allowed(method)){return Promise.reject(new Error('unsupported_bridge_method'));}"
    "    var handler=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.zigSchedulerDesktopBridge;"
    "    if(!handler){return Promise.reject(new Error('native_bridge_handler_missing'));}"
    "    handler.postMessage(method);"
    "    return Promise.resolve({schema:'zig-scheduler/live-vm-webview-bridge/v1',bridge_mode:'webkitgtk-script-message',method:method,queued:true,host_mutation:false});"
    "  }"
    "  var bridge={status:function(){return post('status');},run:function(){return post('run');},rollback:function(){return post('rollback');},stop:function(){return post('stop');},subscribe:function(){return post('subscribe');}};"
    "  Object.freeze(bridge);"
    "  window.ZigSchedulerDesktopBridge=bridge;"
    "  window.zigSchedulerDesktopBridge=bridge;"
    "  if(!window.ZigSchedulerLiveBridge){window.ZigSchedulerLiveBridge=bridge;}"
    "  window.ZigSchedulerLiveBridgeContract=Object.freeze({methods:methods.slice(),bridge_mode:'webkitgtk-script-message',host_mutation:false});"
    "}());";


char *state_path(AppState *state, const char *name) {
    return g_build_filename(state->state_dir, name, NULL);
}


static int has_path_prefix(const char *path, const char *prefix) {
    size_t prefix_len = strlen(prefix);
    return strcmp(path, prefix) == 0 ||
        (strncmp(path, prefix, prefix_len) == 0 && path[prefix_len] == '/');
}

static int is_sensitive_segment(const char *start, size_t len) {
    return (len == 3 && strncmp(start, "sys", len) == 0) ||
        (len == 4 && strncmp(start, "proc", len) == 0) ||
        (len == 6 && strncmp(start, "cgroup", len) == 0) ||
        (len == 7 && strncmp(start, "cgroups", len) == 0) ||
        (len == 6 && strncmp(start, "cpuset", len) == 0) ||
        (len == 7 && strncmp(start, "cpusets", len) == 0);
}

static int state_dir_is_valid(const char *path) {
    if (path == NULL) return 0;
    size_t len = strlen(path);
    if (len == 0 || len > 240) return 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)path[i];
        if (c <= 0x20 || c == 0x7f || c == '=' || c == '"' || c == '\'' || c == '`' ||
            c == '$' || c == '&' || c == '|' || c == ';' || c == '<' || c == '>' ||
            c == '(' || c == ')' || c == '\\') return 0;
    }
    if (path[0] == '/' &&
        !has_path_prefix(path, "/tmp/zig-scheduler-live-vm-desktop") &&
        !has_path_prefix(path, "/var/tmp/zig-scheduler-live-vm-desktop") &&
        strncmp(path, "/tmp/zig-scheduler-live-controller-timeout-", strlen("/tmp/zig-scheduler-live-controller-timeout-")) != 0) return 0;
    const char *segment_base = path[0] == '/' ? path + 1 : path;
    const char *segment = segment_base;
    size_t base_len = strlen(segment_base);
    for (size_t i = 0; i <= base_len; i++) {
        if (segment_base[i] == '/' || segment_base[i] == '\0') {
            size_t segment_len = (size_t)(&segment_base[i] - segment);
            if (segment_len == 0) return 0;
            if ((segment_len == 1 && strncmp(segment, ".", segment_len) == 0) ||
                (segment_len == 2 && strncmp(segment, "..", segment_len) == 0) ||
                is_sensitive_segment(segment, segment_len)) return 0;
            segment = &segment_base[i + 1];
        }
    }
    return 1;
}

int state_dir_has_no_symlink_components(const char *path) {
    if (!state_dir_is_valid(path)) return 0;
    char current[PATH_MAX];
    size_t path_len = strlen(path);
    if (path_len >= sizeof(current)) return 0;

    size_t cursor = 0;
    const char *segment_base = path;
    if (path[0] == '/') {
        current[cursor++] = '/';
        segment_base = path + 1;
    }

    const char *segment = segment_base;
    size_t base_len = strlen(segment_base);
    for (size_t i = 0; i <= base_len; i++) {
        if (segment_base[i] == '/' || segment_base[i] == '\0') {
            size_t segment_len = (size_t)(&segment_base[i] - segment);
            if (cursor > 0 && current[cursor - 1] != '/') {
                if (cursor + 1 >= sizeof(current)) return 0;
                current[cursor++] = '/';
            }
            if (cursor + segment_len >= sizeof(current)) return 0;
            memcpy(&current[cursor], segment, segment_len);
            cursor += segment_len;
            current[cursor] = '\0';

            struct stat st;
            if (lstat(current, &st) != 0) {
                if (errno == ENOENT) return 1;
                return 0;
            }
            if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode)) return 0;
            segment = &segment_base[i + 1];
        }
    }
    return 1;
}

int path_is_symlink(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0 && S_ISLNK(st.st_mode);
}

static void append_json_string(FILE *file, const char *value) {
    fputc('"', file);
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor != '\0'; cursor++) {
        switch (*cursor) {
            case '"': fputs("\\\"", file); break;
            case '\\': fputs("\\\\", file); break;
            case '\n': fputs("\\n", file); break;
            case '\r': fputs("\\r", file); break;
            case '\t': fputs("\\t", file); break;
            default:
                if (*cursor < 0x20) {
                    fprintf(file, "\\u%04x", *cursor);
                } else {
                    fputc(*cursor, file);
                }
        }
    }
    fputc('"', file);
}

void append_log_line(AppState *state, const char *name, const char *tag, const char *text) {
    char *path = state_path(state, name);
    if (path_is_symlink(path)) {
        g_free(path);
        return;
    }
    FILE *file = fopen(path, "a");
    if (file != NULL) {
        fputs("{\"tag\":", file);
        append_json_string(file, tag);
        fputs(",\"text\":", file);
        append_json_string(file, text);
        fputs("}\n", file);
        fclose(file);
    }
    g_free(path);
}

void append_controller_events(AppState *state, const char *stdout_text) {
    char *path = state_path(state, "events.jsonl");
    if (path_is_symlink(path)) {
        g_free(path);
        return;
    }
    FILE *file = fopen(path, "a");
    if (file != NULL) {
        const char *cursor = stdout_text;
        while (*cursor != '\0') {
            const char *line_end = strchr(cursor, '\n');
            size_t len = line_end == NULL ? strlen(cursor) : (size_t)(line_end - cursor);
            if (len > 0 && cursor[0] == '{') {
                fwrite(cursor, 1, len, file);
                fputc('\n', file);
            }
            if (line_end == NULL) break;
            cursor = line_end + 1;
        }
        fclose(file);
    }
    g_free(path);
}

gboolean stdout_contains(const char *stdout_text, const char *needle) {
    return stdout_text != NULL && strstr(stdout_text, needle) != NULL;
}
