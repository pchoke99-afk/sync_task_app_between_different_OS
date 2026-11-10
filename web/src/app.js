import { TaskStore, newRecordId } from "./tasks.js";
import { Calendar } from "./calendar.js";

const $ = (selector) => document.querySelector(selector);
const state = {
  session: null,
  store: null,
  filter: "all",
  syncing: false,
  chatBusy: false,
  conversation: null,
  messages: [],
  proposals: [],
  hasMore: false,
  imageText: "",
  imageUrl: null,
  imageBusy: false,
  recognition: null,
  epoch: 0,
  calendar: new Calendar(),
  calendarIncluded: false,
};
const requestControllers = new Set();
let toastTimer;
let imageGeneration = 0;
let sessionRefresh = null;

function toast(message) {
  $("#toast").textContent = message;
  $("#toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    $("#toast").hidden = true;
  }, 7000);
}
function errorAt(selector, error) {
  $(selector).textContent =
    error.message || "Something went wrong. Please try again.";
}
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function button(label, action, className = "quiet") {
  const node = element("button", className, label);
  node.type = "button";
  node.addEventListener("click", action);
  return node;
}
async function confirmAction(title, details) {
  const dialog = $("#confirm-dialog");
  $("#confirm-title").textContent = title;
  $("#confirm-details").textContent = details;
  dialog.returnValue = "";
  dialog.showModal();
  return new Promise((resolve) =>
    dialog.addEventListener(
      "close",
      () => resolve(dialog.returnValue === "confirm"),
      { once: true },
    ),
  );
}
function saveSession(session) {
  state.session = session;
  // Never persist a password or a Google token. Session storage is cleared on tab closure.
  try {
    sessionStorage.setItem("sync-task-session", JSON.stringify(session));
  } catch {
    toast("This browser cannot remember sign-in. Keep this tab open.");
  }
}
function logout() {
  state.epoch++;
  for (const controller of requestControllers) controller.abort();
  state.recognition?.abort();
  state.recognition = null;
  state.calendar.disconnect();
  state.calendar = new Calendar();
  state.calendarIncluded = false;
  state.session = null;
  state.store = null;
  state.conversation = null;
  state.messages = [];
  state.proposals = [];
  state.chatBusy = false;
  state.syncing = false;
  removeImage();
  $("#message").value = "";
  $("#messages").replaceChildren();
  $("#tasks").replaceChildren();
  try {
    sessionStorage.removeItem("sync-task-session");
  } catch {
    /* Memory-only session. */
  }
  document.querySelectorAll("dialog[open]").forEach((dialog) => dialog.close());
  $("#task-view").hidden = true;
  $("#login-view").hidden = false;
  updateChatBusy();
}

async function api(
  path,
  { method = "GET", body, auth = true, timeout = 20000, signal } = {},
) {
  const controller = new AbortController();
  requestControllers.add(controller);
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  const timer = setTimeout(() => controller.abort(), timeout);
  const epoch = state.epoch;
  try {
    const response = await fetch(path, {
      method,
      credentials: "omit",
      cache: "no-store",
      headers: {
        ...(body ? { "Content-Type": "application/json" } : {}),
        ...(auth && state.session
          ? { Authorization: `Bearer ${state.session.token}` }
          : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: controller.signal,
    });
    if (epoch !== state.epoch)
      throw new Error("Account changed. Please retry.");
    if (response.status === 204) return null;
    let data;
    try {
      data = await response.json();
    } catch {
      throw new Error(
        "The service returned an unexpected response. Check your server connection.",
      );
    }
    if (!response.ok) {
      if (
        auth &&
        (response.status === 401 ||
          (path.endsWith("/auth-refresh") &&
            [400, 403].includes(response.status)))
      ) {
        logout();
        throw new Error("Please sign in again.");
      }
      const error = new Error(
        path.startsWith("/ai/") && typeof data.error === "string"
          ? data.error
          : response.status === 404
            ? "Record not found."
            : response.status === 429
              ? "Too many requests. Wait a moment and try again."
              : response.status === 400
                ? "Please check the fields and try again."
                : "The service is unavailable. Check Tailscale and your server.",
      );
      error.status = response.status;
      throw error;
    }
    return data;
  } catch (error) {
    if (error.name === "AbortError")
      throw new Error(
        "The request stopped or timed out. Check tasks before retrying a change.",
      );
    if (error instanceof TypeError)
      throw new Error(
        "Unable to reach your home server. Check Tailscale and your connection.",
      );
    throw error;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", abort);
    requestControllers.delete(controller);
  }
}

function enterApp(session) {
  saveSession(session);
  const epoch = state.epoch;
  state.store = new TaskStore(session.record.id, (path, options) => {
    if (state.epoch !== epoch) throw new Error("Account changed.");
    return api(path, options);
  });
  $("#login-view").hidden = true;
  $("#task-view").hidden = false;
  $("#today").textContent = new Intl.DateTimeFormat(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
  })
    .format(new Date())
    .toUpperCase();
  renderTasks();
  syncTasks();
  const clientId = readClientId();
  if (clientId) state.calendar.prepare(clientId).catch(() => {});
}

async function refreshSession() {
  if (sessionRefresh) return sessionRefresh;
  if (!state.session) return;
  const epoch = state.epoch;
  sessionRefresh = api("/pb/api/collections/users/auth-refresh", {
    method: "POST",
  })
    .then((data) => {
      if (state.epoch === epoch) saveSession(data);
    })
    .finally(() => {
      sessionRefresh = null;
    });
  return sessionRefresh;
}
async function syncTasks() {
  if (!state.store || state.syncing || !navigator.onLine) {
    renderSync();
    return;
  }
  const store = state.store;
  state.syncing = true;
  renderSync();
  try {
    await store.sync();
    if (state.store === store) {
      $("#task-error").textContent = "";
      renderTasks();
    }
  } catch (error) {
    if (state.store === store) errorAt("#task-error", error);
  } finally {
    if (state.store === store) {
      state.syncing = false;
      renderSync();
    }
  }
}
function renderSync() {
  const status = $("#sync-status");
  const pending = state.store?.queue.length ?? 0;
  status.textContent = !navigator.onLine
    ? `Offline${pending ? ` · ${pending} queued` : ""}`
    : state.syncing
      ? "Syncing"
      : pending
        ? `${pending} pending`
        : "In sync";
  status.classList.toggle("offline", !navigator.onLine || pending > 0);
  $("#sync").disabled = state.syncing;
}
function renderTasks() {
  if (!state.store) return;
  const tasks = state.store.tasks;
  const complete = tasks.filter((task) => task.is_completed).length;
  const progress = tasks.length
    ? Math.round((complete / tasks.length) * 100)
    : 0;
  $("#progress-label").textContent =
    `${complete} of ${tasks.length} tasks completed`;
  $("#progress-percent").textContent = `${progress}%`;
  $("#progress").value = progress;
  $("#task-count").textContent = String(tasks.length);
  const visible = tasks.filter(
    (task) =>
      state.filter === "all" ||
      (state.filter === "done") === Boolean(task.is_completed),
  );
  const list = $("#tasks");
  list.replaceChildren();
  for (const task of visible) {
    const row = element("article", `task${task.is_completed ? " done" : ""}`);
    const checkbox = element("input", "task-check");
    checkbox.type = "checkbox";
    checkbox.checked = task.is_completed;
    checkbox.setAttribute(
      "aria-label",
      `Mark ${task.title} ${task.is_completed ? "incomplete" : "complete"}`,
    );
    checkbox.addEventListener("change", () => {
      const completed = checkbox.checked;
      try {
        state.store.edit(task.id, {
          is_completed: completed,
          completed_at: completed ? new Date().toISOString() : "",
        });
        if (completed) confetti();
        renderTasks();
        syncTasks();
      } catch (error) {
        errorAt("#task-error", error);
        renderTasks();
      }
    });
    const content = element("div", "task-content");
    content.append(element("h3", "task-title", task.title));
    if (task.description)
      content.append(element("p", "task-description", task.description));
    if (task.due_at)
      content.append(
        element(
          "p",
          "task-description",
          `Due ${new Date(task.due_at).toLocaleString()}`,
        ),
      );
    if (task.scheduled_at)
      content.append(
        element(
          "p",
          "task-description",
          `Scheduled ${new Date(task.scheduled_at).toLocaleString()}`,
        ),
      );
    if (task.estimated_minutes)
      content.append(
        element(
          "p",
          "task-description",
          `${task.estimated_minutes} min estimated`,
        ),
      );
    if (task.category)
      content.append(element("p", "task-description", task.category));
    const priority = ["high", "normal", "low"].includes(task.priority)
      ? task.priority
      : "normal";
    content.append(
      element(
        "span",
        `priority ${priority}`,
        `${priority[0].toUpperCase()}${priority.slice(1)} priority`,
      ),
    );
    const actions = element("div", "task-actions");
    const edit = button("✎", () => editTask(task), "icon-button");
    edit.setAttribute("aria-label", `Edit ${task.title}`);
    const remove = button(
      "×",
      async () => {
        if (!(await confirmAction("Delete this task?", task.title))) return;
        try {
          state.store.edit(task.id, {}, "DELETE");
          renderTasks();
          syncTasks();
        } catch (error) {
          errorAt("#task-error", error);
        }
      },
      "icon-button",
    );
    remove.setAttribute("aria-label", `Delete ${task.title}`);
    actions.append(edit, remove);
    row.append(checkbox, content, actions);
    list.append(row);
  }
  $("#empty").hidden = visible.length > 0;
  renderSync();
}
function editTask(task) {
  $("#task-dialog-title").textContent = task ? "Edit task" : "A new beginning";
  $("#task-id").value = task?.id ?? "";
  $("#task-title").value = task?.title ?? "";
  $("#task-description").value = task?.description ?? "";
  $("#task-priority").value = task?.priority ?? "normal";
  $("#task-dialog").showModal();
  $("#task-title").focus();
}

function updateChatBusy() {
  $("#chat-busy").hidden = !state.chatBusy;
  $("#chat-dialog").setAttribute("aria-busy", String(state.chatBusy));
  $("#chat-dialog .rings").classList.toggle(
    "active",
    state.chatBusy || Boolean(state.recognition),
  );
  for (const selector of [
    "#chat-form button[type=submit]",
    "#new-chat",
    "#conversations",
    "#calendar",
  ]) {
    $(selector).disabled =
      state.chatBusy || (selector.includes("submit") && state.imageBusy);
  }
  $("#attach").disabled = state.chatBusy || state.imageBusy;
  $("#microphone").disabled = state.chatBusy;
  $("#image-file").disabled = state.chatBusy;
  $("#message").readOnly = state.chatBusy;
}
async function chatAction(action) {
  if (state.chatBusy) return;
  const epoch = state.epoch;
  state.chatBusy = true;
  $("#chat-error").textContent = "";
  updateChatBusy();
  try {
    await action(epoch);
  } catch (error) {
    if (epoch === state.epoch) errorAt("#chat-error", error);
  } finally {
    if (epoch === state.epoch) {
      state.chatBusy = false;
      updateChatBusy();
    }
  }
}
async function listConversations() {
  const epoch = state.epoch;
  const data = await api("/ai/conversations");
  if (state.epoch !== epoch) return;
  const select = $("#conversations");
  select.replaceChildren(new Option("New conversation", ""));
  for (const conversation of data.conversations)
    select.add(new Option(conversation.title, conversation.id));
  select.value = state.conversation ?? "";
}
async function openConversation(id, before = null) {
  const epoch = state.epoch;
  const data = await api(
    `/ai/conversations/${encodeURIComponent(id)}${before ? `?before_message=${encodeURIComponent(before)}` : ""}`,
  );
  if (state.epoch !== epoch) return;
  state.conversation = id;
  state.messages = before
    ? [...data.messages, ...state.messages]
    : data.messages;
  state.proposals = data.proposals;
  state.hasMore = data.has_more;
  renderChat();
}
function renderChat() {
  const container = $("#messages");
  container.replaceChildren();
  if (!state.messages.length) {
    const welcome = element("section", "welcome");
    const rings = $("#open-chat .rings").cloneNode(true);
    welcome.append(
      rings,
      element("h3", "", "A clearer plan starts here."),
      element(
        "p",
        "muted",
        "Create tasks, untangle your plans, or find your next step. You approve changes before they are saved.",
      ),
    );
    const suggestions = element("div", "suggestions");
    for (const text of [
      "What should I work on today?",
      "Help me plan my study time",
      "Organize my tasks",
    ]) {
      suggestions.append(
        button(`✧  ${text}`, () => {
          $("#message").value = text;
          $("#message").focus();
        }),
      );
    }
    welcome.append(suggestions);
    container.append(welcome);
  }
  if (state.hasMore && state.messages.length) {
    container.append(
      button("Load earlier messages", () =>
        chatAction(() =>
          openConversation(state.conversation, state.messages[0].id),
        ),
      ),
    );
  }
  for (const message of state.messages) {
    const card = element(
      "article",
      `message${message.role === "user" ? " user" : ""}`,
    );
    card.append(
      element("strong", "", message.role === "user" ? "YOU" : "HALO"),
      document.createTextNode(String(message.content ?? "")),
    );
    container.append(card);
  }
  for (const proposal of state.proposals) {
    const card = element("section", "proposal");
    card.append(
      element(
        "h3",
        "",
        proposal.status === "pending"
          ? "Your plan, for review"
          : `Changes: ${proposal.status.replaceAll("_", " ")}`,
      ),
    );
    const list = element("ul");
    for (const operation of proposal.operations ?? []) {
      const item = element(
        "li",
        "",
        `${operation.name.replaceAll("_", " ")} · ${operation.preview_title ?? ""}`,
      );
      const fields = operation.arguments?.fields ?? operation.arguments ?? {};
      const details = Object.entries(fields)
        .filter(([key]) => key !== "task_id")
        .map(([key, value]) => `${key.replaceAll("_", " ")}: ${String(value)}`)
        .join("\n");
      item.append(element("pre", "", details));
      list.append(item);
    }
    card.append(list);
    if (proposal.status === "pending") {
      const actions = element("div", "proposal-actions");
      actions.append(
        button("Review and apply", () => decide(proposal, true), "primary"),
        button("Dismiss", () => decide(proposal, false)),
      );
      card.append(actions);
    }
    if (proposal.result)
      card.append(
        element("pre", "pre-wrap", JSON.stringify(proposal.result, null, 2)),
      );
    container.append(card);
  }
}
async function decide(proposal, apply) {
  if (state.chatBusy) return;
  if (
    apply &&
    !(await confirmAction(
      "Apply these task changes?",
      proposal.operations
        .map(
          (op) => `${op.name.replaceAll("_", " ")}: ${op.preview_title ?? ""}`,
        )
        .join("\n"),
    ))
  )
    return;
  await chatAction(async (epoch) => {
    const result = await api(
      `/ai/proposals/${encodeURIComponent(proposal.id)}/decision`,
      { method: "POST", body: { confirm: apply }, timeout: 60000 },
    );
    if (epoch !== state.epoch) return;
    await openConversation(state.conversation);
    await syncTasks();
    if (result.status === "partial_or_failed")
      throw new Error(
        "Some changes could not be applied. Review your tasks before requesting a new proposal.",
      );
    toast(apply ? "Task changes reviewed and applied." : "Proposal dismissed.");
  });
}

function removeImage() {
  imageGeneration++;
  if (state.imageUrl) URL.revokeObjectURL(state.imageUrl);
  state.imageUrl = null;
  state.imageText = "";
  $("#image-draft").hidden = true;
  $("#image-preview").removeAttribute("src");
  $("#image-file").value = "";
}
async function attachImage(file) {
  if (!file || state.imageBusy || state.chatBusy) return;
  if (!file.type.startsWith("image/") || file.size > 10 * 1024 * 1024) {
    errorAt("#chat-error", new Error("Choose an image smaller than 10 MB."));
    return;
  }
  removeImage();
  const generation = imageGeneration;
  const epoch = state.epoch;
  state.imageBusy = true;
  state.imageUrl = URL.createObjectURL(file);
  $("#image-preview").src = state.imageUrl;
  $("#image-status").textContent = "Reading text on this device…";
  $("#image-draft").hidden = false;
  updateChatBusy();
  let worker;
  try {
    await loadOCR();
    worker = await Tesseract.createWorker("eng", 1, {
      workerPath: "/vendor/worker.min.js",
      corePath: "/vendor/core",
      langPath: "/vendor/lang",
      workerBlobURL: false,
    });
    const result = await worker.recognize(file);
    if (epoch !== state.epoch || generation !== imageGeneration) return;
    state.imageText = result.data.text.trim();
    $("#image-status").textContent = state.imageText
      ? "Text extracted. Review it below before sending."
      : "No readable text. The AI cannot see images.";
    if (state.imageText) {
      const extracted = `Text extracted from an attached image (may contain errors):\n${state.imageText}`;
      const draft = [$("#message").value, extracted]
        .filter(Boolean)
        .join("\n\n");
      if (draft.length > 4000)
        throw new Error(
          "Extracted text exceeds 4,000 characters. Use a smaller screenshot.",
        );
      $("#message").value = draft;
    }
  } catch (error) {
    if (epoch === state.epoch && generation === imageGeneration) {
      $("#image-status").textContent = "Text recognition unavailable.";
      errorAt("#chat-error", error);
    }
  } finally {
    await worker?.terminate();
    state.imageBusy = false;
    updateChatBusy();
  }
}
let ocrScript;
function loadOCR() {
  ocrScript ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "/vendor/tesseract.min.js";
    script.onload = resolve;
    script.onerror = () => {
      ocrScript = null;
      script.remove();
      reject(
        new Error("Image recognition could not load. Reconnect and try again."),
      );
    };
    document.head.append(script);
  });
  return ocrScript;
}
function readClientId() {
  try {
    return localStorage.getItem("sync-task-google-client-id") ?? "";
  } catch {
    return "";
  }
}
function openSettings() {
  $("#google-client-id").value = readClientId();
  $("#oauth-origin").textContent = location.origin;
  $("#pending-summary").textContent =
    `${state.store?.queue.length ?? 0} unsynced edits on this device. Export them before discarding a conflict.`;
  $("#settings-dialog").showModal();
}

// One short, bounded animation; no GIF decoding or idle animation loop.
let confettiFrame;
function confetti() {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  cancelAnimationFrame(confettiFrame);
  const canvas = $("#confetti"),
    ctx = canvas.getContext("2d");
  const width = innerWidth,
    height = innerHeight,
    ratio = Math.min(devicePixelRatio, 2);
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  ctx.scale(ratio, ratio);
  const colors = ["#8ec9ff", "#72dce9", "#b7d2ff", "#ecce93"];
  const particles = Array.from({ length: 70 }, () => ({
    x: width / 2,
    y: height * 0.4,
    vx: (Math.random() - 0.5) * 11,
    vy: -Math.random() * 9 - 2,
    r: Math.random() * Math.PI,
    color: colors[Math.floor(Math.random() * colors.length)],
  }));
  const start = performance.now();
  let last = start;
  const draw = (now) => {
    ctx.clearRect(0, 0, width, height);
    if (now - start > 1800) return;
    const step = Math.min((now - last) / 16.67, 3);
    last = now;
    ctx.globalAlpha = Math.max(0, 1 - (now - start) / 1800);
    for (const p of particles) {
      p.vy += 0.16 * step;
      p.x += p.vx * step;
      p.y += p.vy * step;
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate((p.r += 0.06 * step));
      ctx.fillStyle = p.color;
      ctx.fillRect(-3, -3, 6, 9);
      ctx.restore();
    }
    confettiFrame = requestAnimationFrame(draw);
  };
  confettiFrame = requestAnimationFrame(draw);
}

$("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = $("#login-form button[type=submit]");
  submit.disabled = true;
  $("#login-error").textContent = "";
  try {
    const session = await api("/pb/api/collections/users/auth-with-password", {
      method: "POST",
      auth: false,
      body: {
        identity: $("#email").value.trim(),
        password: $("#password").value,
      },
    });
    $("#password").value = "";
    enterApp(session);
  } catch (error) {
    errorAt("#login-error", error);
  } finally {
    submit.disabled = false;
  }
});
$("#logout").addEventListener("click", async () => {
  if (
    state.store?.queue.length &&
    !(await confirmAction(
      "Sign out with pending edits?",
      "Your unsynced edits will remain on this browser for this account. Sign back in on this device to sync them.",
    ))
  )
    return;
  logout();
});
$("#sync").addEventListener("click", syncTasks);
$("#add-task").addEventListener("click", () => editTask());
$("#task-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const title = $("#task-title").value.trim();
  if (!title) {
    $("#task-title").focus();
    return;
  }
  const id = $("#task-id").value;
  try {
    state.store.edit(
      id || newRecordId(),
      {
        title,
        description: $("#task-description").value.trim(),
        priority: $("#task-priority").value,
        ...(!id ? { is_completed: false, completed_at: "" } : {}),
      },
      id ? "PATCH" : "POST",
    );
    $("#task-dialog").close();
    renderTasks();
    syncTasks();
  } catch (error) {
    toast(error.message);
    renderTasks();
  }
});
for (const node of document.querySelectorAll("[data-close]"))
  node.addEventListener("click", () => $(`#${node.dataset.close}`).close());
for (const node of document.querySelectorAll("[data-filter]"))
  node.addEventListener("click", () => {
    state.filter = node.dataset.filter;
    document.querySelectorAll("[data-filter]").forEach((item) => {
      item.classList.toggle("selected", item === node);
      item.setAttribute("aria-pressed", String(item === node));
    });
    renderTasks();
  });
$("#open-chat").addEventListener("click", () => {
  $("#chat-dialog").showModal();
  renderChat();
  chatAction(listConversations);
});
$("#new-chat").addEventListener("click", () => {
  state.conversation = null;
  state.messages = [];
  state.proposals = [];
  state.hasMore = false;
  $("#conversations").value = "";
  renderChat();
});
$("#conversations").addEventListener("change", (event) => {
  if (event.target.value)
    chatAction(() => openConversation(event.target.value));
  else $("#new-chat").click();
});
$("#chat-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const message = $("#message").value.trim();
  if (!message || state.imageBusy || state.recognition) return;
  if (message.length > 4000) {
    errorAt(
      "#chat-error",
      new Error("Shorten the message to 4,000 characters."),
    );
    return;
  }
  chatAction(async (epoch) => {
    const availability = state.calendarIncluded
      ? await state.calendar.availability()
      : null;
    const data = await api("/ai/chat", {
      method: "POST",
      timeout: 500000,
      body: {
        message,
        conversation_id: state.conversation,
        local_time: new Date().toISOString(),
        time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        ...(availability ? { calendar_availability: availability } : {}),
      },
    });
    if (epoch !== state.epoch) return;
    $("#message").value = "";
    removeImage();
    await openConversation(data.conversation_id);
    await listConversations();
    $("#messages").scrollTop = $("#messages").scrollHeight;
  });
});
$("#settings").addEventListener("click", openSettings);
$("#settings-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const id = $("#google-client-id").value.trim();
  if (id && !id.endsWith(".apps.googleusercontent.com")) {
    toast("Enter a valid Google Web application client ID.");
    return;
  }
  try {
    localStorage.setItem("sync-task-google-client-id", id);
  } catch {
    toast("Browser storage is unavailable.");
    return;
  }
  state.calendar.disconnect();
  state.calendarIncluded = false;
  $("#calendar").textContent = "▦ Connect Calendar";
  $("#settings-dialog").close();
  if (id) {
    try {
      await state.calendar.prepare(id);
      toast("Calendar is ready. Open chat and tap Connect Calendar.");
    } catch (error) {
      toast(error.message);
    }
  }
});
$("#calendar").addEventListener("click", async () => {
  if (state.calendarIncluded) {
    state.calendar.disconnect();
    state.calendarIncluded = false;
    $("#calendar").textContent = "▦ Connect Calendar";
    return;
  }
  const clientId = readClientId();
  if (!clientId) {
    openSettings();
    return;
  }
  if (!state.calendar.client) {
    try {
      await state.calendar.prepare(clientId);
      toast("Google sign-in is ready. Tap Connect Calendar again.");
    } catch (error) {
      errorAt("#chat-error", error);
    }
    return;
  }
  const epoch = state.epoch;
  try {
    await state.calendar.connect();
    if (epoch === state.epoch) {
      state.calendarIncluded = true;
      $("#calendar").textContent = "▦ Calendar connected · disconnect";
    }
  } catch (error) {
    if (epoch === state.epoch) errorAt("#chat-error", error);
  }
});
$("#attach").addEventListener("click", () => $("#image-file").click());
$("#image-file").addEventListener("change", (event) =>
  attachImage(event.target.files[0]),
);
$("#remove-image").addEventListener("click", removeImage);
$("#message").addEventListener("paste", (event) => {
  const item = [...(event.clipboardData?.items ?? [])].find((entry) =>
    entry.type.startsWith("image/"),
  );
  if (item) {
    event.preventDefault();
    attachImage(item.getAsFile());
  }
});
const SpeechRecognition =
  globalThis.SpeechRecognition || globalThis.webkitSpeechRecognition;
$("#microphone").addEventListener("click", () => {
  if (!SpeechRecognition) {
    toast(
      "Use the microphone on your iPhone keyboard to dictate into the message box.",
    );
    $("#message").focus();
    return;
  }
  if (state.recognition) {
    state.recognition.stop();
    return;
  }
  if (
    !confirm(
      "Browser dictation may send audio to your browser provider. Continue? You can also use keyboard dictation.",
    )
  )
    return;
  const recognition = new SpeechRecognition();
  const draft = $("#message").value;
  const epoch = state.epoch;
  recognition.lang = navigator.language;
  recognition.interimResults = false;
  recognition.onresult = (event) => {
    if (epoch === state.epoch)
      $("#message").value = [draft, event.results[0][0].transcript]
        .filter(Boolean)
        .join(" ")
        .slice(0, 4000);
  };
  recognition.onerror = () => {
    if (epoch === state.epoch)
      toast("Dictation unavailable. Try the keyboard microphone.");
  };
  recognition.onend = () => {
    if (state.recognition === recognition) {
      state.recognition = null;
      $("#microphone").textContent = "♩";
      updateChatBusy();
    }
  };
  state.recognition = recognition;
  $("#microphone").textContent = "■";
  updateChatBusy();
  try {
    recognition.start();
  } catch {
    recognition.onend();
    toast("Microphone could not start.");
  }
});
window.addEventListener("online", syncTasks);
window.addEventListener("offline", renderSync);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && state.session)
    refreshSession()
      .then(syncTasks)
      .catch((error) => errorAt("#task-error", error));
});
setInterval(() => {
  if (!document.hidden) syncTasks();
}, 30000);
setInterval(() => {
  if (state.session && !document.hidden)
    refreshSession().catch((error) => errorAt("#task-error", error));
}, 5 * 60000);
window.addEventListener("beforeunload", (event) => {
  if (state.chatBusy || state.store?.queue.length) {
    event.preventDefault();
    event.returnValue = "";
  }
});
if ("serviceWorker" in navigator && isSecureContext)
  navigator.serviceWorker.register("/sw.js").catch(() => {});
try {
  const saved = JSON.parse(
    sessionStorage.getItem("sync-task-session") || "null",
  );
  if (saved?.token && /^[a-z0-9]{15}$/.test(saved.record?.id ?? "")) {
    saveSession(saved);
    refreshSession()
      .then(() => {
        if (state.session) enterApp(state.session);
      })
      .catch((error) => {
        if (!navigator.onLine && state.session) enterApp(state.session);
        else errorAt("#login-error", error);
      });
  }
} catch {
  /* Start with a fresh sign-in if session storage is unavailable. */
}

$("#export-edits").addEventListener("click", () => {
  if (!state.store) return;
  const blob = new Blob(
    [
      JSON.stringify(
        { tasks: state.store.tasks, queue: state.store.queue },
        null,
        2,
      ),
    ],
    { type: "application/json" },
  );
  const url = URL.createObjectURL(blob);
  const link = element("a");
  link.href = url;
  link.download = "sync-task-offline-edits.json";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
$("#discard-edits").addEventListener("click", async () => {
  if (!state.store?.queue.length) {
    toast("No queued edits to discard.");
    return;
  }
  if (
    !(await confirmAction(
      "Discard unsynced edits?",
      "This removes your queued edits from this browser. It does not change server tasks. Export your edits first if you want to keep a copy.",
    ))
  )
    return;
  state.store.queue = [];
  state.store.tasks = [];
  try {
    state.store.persist();
  } catch (error) {
    toast(error.message);
  }
  $("#settings-dialog").close();
  renderTasks();
  await syncTasks();
});
