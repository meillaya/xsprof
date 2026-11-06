// Hidden DOM/ARIA mirror of the GPU accessibility tree. The canvas remains
// the pointer and keyboard owner; this mirror makes the same bounded tree
// discoverable to screen readers and exposes activation for assistive tech.
let lastSignature = "";

const ROLE_NAMES = {
  window: "document",
  tablist: "tablist",
  tab: "tab",
  tabpanel: "region",
  button: "button",
  textbox: "textbox",
  list: "list",
  listitem: "listitem",
  dialog: "dialog",
  status: "status",
  heading: "heading",
  progressbar: "progressbar",
};

export function syncA11y(exports, root) {
  if (!exports?.web_ui_a11y_ptr || !exports?.web_ui_a11y_len) return;
  const ptr = exports.web_ui_a11y_ptr();
  const len = exports.web_ui_a11y_len();
  if (!ptr || !len) return;
  const text = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, ptr, len));
  if (text === lastSignature) return;
  lastSignature = text;
  let tree;
  try {
    tree = JSON.parse(text);
  } catch (_) {
    return;
  }
  const fragment = document.createDocumentFragment();
  const nodes = Array.isArray(tree.nodes) ? tree.nodes : [];
  for (const node of nodes) {
    if (!node || !node.id || !node.label) continue;
    const role = ROLE_NAMES[node.role] || "group";
    const element = document.createElement(role === "document" ? "div" : "button");
    element.type = role === "document" ? undefined : "button";
    element.setAttribute("role", role);
    element.setAttribute("aria-label", node.label);
    if (node.value) element.setAttribute("aria-valuetext", node.value);
    if (node.selected) element.setAttribute("aria-selected", "true");
    if (node.disabled) element.setAttribute("aria-disabled", "true");
    element.tabIndex = node.focusable ? 0 : -1;
    element.dataset.id = String(node.id);
    if (role === "button" || role === "tab" || role === "listitem") {
      element.addEventListener("focus", () => exports.web_ui_a11y_focus?.(node.id));
      element.addEventListener("click", () => exports.web_ui_a11y_activate?.(node.id));
    }
    fragment.appendChild(element);
  }
  root.replaceChildren(fragment);
}

export function announce(root, text) {
  if (!root || !text) return;
  root.textContent = text;
}
