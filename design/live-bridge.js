// live-bridge.js — strict WebView/browser-source bridge for the VM-lab-only UI.
(function () {
  'use strict';

  const CONTRACT = Object.freeze(['status', 'run', 'rollback', 'stop', 'subscribe']);
  const ACTION_PATHS = Object.freeze({
    run: '/api/action/run',
    rollback: '/api/action/rollback',
    stop: '/api/action/stop',
  });
  const INCIDENT_SCHEMA = 'zig-scheduler/daemon-event/v1';
  let sourceNonce = '';

  function incident(method, reason) {
    return {
      schema: INCIDENT_SCHEMA,
      event: 'incident',
      action: 'live_vm_bridge',
      bridge_method: String(method || ''),
      status: 'refused',
      reason,
      host_mutation: false,
    };
  }

  function bridgeError(method, reason, event) {
    const err = new Error(reason);
    err.event = event || incident(method, reason);
    return err;
  }

  function isAllowed(method) {
    return CONTRACT.indexOf(method) !== -1;
  }

  function nativeHost() {
    const host = window.ZigSchedulerDesktopBridge || window.zigSchedulerDesktopBridge || null;
    return host && typeof host === 'object' ? host : null;
  }

  async function callNative(method) {
    if (!isAllowed(method)) throw bridgeError(method, 'unsupported_bridge_method');
    const host = nativeHost();
    if (!host || typeof host[method] !== 'function') throw bridgeError(method, 'native_bridge_method_missing');
    const result = await host[method]();
    if (result && typeof result === 'object') {
      if (result.host_mutation !== false) throw bridgeError(method, 'host_mutation_not_false');
      return Object.assign({ bridge_mode: 'webkitgtk-script-message', host_mutation: false }, result);
    }
    return { schema: 'zig-scheduler/live-vm-web/v1', bridge_mode: 'webkitgtk-script-message', host_mutation: false };
  }

  async function sourceStatus() {
    try {
      const res = await fetch('/api/status', { cache: 'no-store', credentials: 'same-origin' });
      if (!res.ok) throw new Error('status ' + res.status);
      const body = await res.json();
      sourceNonce = typeof body.bridge_nonce === 'string' ? body.bridge_nonce : '';
      return Object.assign({ bridge_mode: 'browser-source', host_mutation: false }, body);
    } catch (err) {
      return {
        connected: false,
        mode: 'design-simulation',
        bridge_mode: 'design-simulation',
        host_mutation: false,
        error: String(err && err.message || err),
      };
    }
  }

  async function sourceAction(method) {
    if (!Object.prototype.hasOwnProperty.call(ACTION_PATHS, method)) {
      throw bridgeError(method, 'unsupported_bridge_method');
    }
    if (!sourceNonce) await sourceStatus();
    if (!sourceNonce) throw bridgeError(method, 'missing_bridge_nonce');
    const res = await fetch(ACTION_PATHS[method], {
      method: 'POST',
      cache: 'no-store',
      credentials: 'same-origin',
      headers: { 'X-ZigScheduler-Bridge-Nonce': sourceNonce },
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok && res.status !== 202) {
      const event = body && typeof body === 'object' ? body : incident(method, 'bridge_http_refused');
      const err = bridgeError(method, event.reason || event.error || ('action ' + res.status), event);
      throw err;
    }
    return Object.assign({ bridge_mode: 'browser-source', host_mutation: false }, body);
  }

  const api = Object.freeze({
    async status() {
      const host = nativeHost();
      if (host && typeof host.status === 'function') return callNative('status');
      return sourceStatus();
    },
    async run() {
      const host = nativeHost();
      if (host && typeof host.run === 'function') return callNative('run');
      return sourceAction('run');
    },
    async rollback() {
      const host = nativeHost();
      if (host && typeof host.rollback === 'function') return callNative('rollback');
      return sourceAction('rollback');
    },
    async stop() {
      const host = nativeHost();
      if (host && typeof host.stop === 'function') return callNative('stop');
      return sourceAction('stop');
    },
    subscribe(onEvent, onError) {
      const host = nativeHost();
      if (host && typeof host.subscribe === 'function') return host.subscribe(onEvent, onError);
      if (typeof EventSource === 'undefined') return function () {};
      const source = new EventSource('/api/events');
      source.onmessage = (msg) => {
        try { onEvent(JSON.parse(msg.data)); }
        catch (err) { if (onError) onError(err); }
      };
      source.onerror = (err) => { if (onError) onError(err); };
      return () => source.close();
    },
  });

  window.ZigSchedulerLiveBridge = api;
  window.ZigSchedulerLiveBridgeContract = Object.freeze({
    methods: CONTRACT.slice(),
    host_mutation: false,
  });
})();
