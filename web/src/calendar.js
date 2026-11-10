const scope = "https://www.googleapis.com/auth/calendar.freebusy";
let scriptPromise;
function loadIdentity() {
  scriptPromise ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "https://accounts.google.com/gsi/client";
    script.onload = resolve;
    script.onerror = () => {
      scriptPromise = null;
      script.remove();
      reject(
        new Error("Google sign-in could not load. Check your connection."),
      );
    };
    document.head.append(script);
  });
  return scriptPromise;
}

/** Short-lived Google token stays in memory and is never sent to the AI endpoint. */
export class Calendar {
  token = null;
  expiry = 0;
  clientId = "";
  client = null;
  async prepare(clientId) {
    if (!clientId.endsWith(".apps.googleusercontent.com"))
      throw new Error(
        "Add a Web application OAuth client ID in Settings first. Desktop clients are not supported here.",
      );
    await loadIdentity();
    this.clientId = clientId;
    this.client = google.accounts.oauth2.initTokenClient({
      client_id: clientId,
      scope,
      callback: () => {},
    });
  }
  connect() {
    if (!this.client)
      throw new Error(
        "Google sign-in is loading. Tap Connect Calendar again in a moment.",
      );
    return new Promise((resolve, reject) => {
      this.client.callback = (response) => {
        if (
          response.error ||
          !google.accounts.oauth2.hasGrantedAllScopes(response, scope)
        ) {
          reject(new Error("Google Calendar permission was not granted."));
          return;
        }
        this.token = response.access_token;
        this.expiry = Date.now() + (Number(response.expires_in) - 60) * 1000;
        resolve();
      };
      this.client.error_callback = () =>
        reject(
          new Error(
            "Google sign-in was closed or blocked. Allow the sign-in popup and try again.",
          ),
        );
      this.client.requestAccessToken({ prompt: "select_account" });
    });
  }
  get connected() {
    return Boolean(this.token && this.expiry > Date.now());
  }
  disconnect() {
    if (this.token && globalThis.google?.accounts?.oauth2)
      google.accounts.oauth2.revoke(this.token, () => {});
    this.token = null;
    this.expiry = 0;
    this.client = null;
  }
  async availability() {
    if (!this.connected)
      throw new Error(
        "Calendar access expired. Reconnect Calendar before using your busy times.",
      );
    const start = new Date();
    const end = new Date(start.getTime() + 14 * 86400000);
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const response = await fetch(
      "https://www.googleapis.com/calendar/v3/freeBusy",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          timeMin: start.toISOString(),
          timeMax: end.toISOString(),
          timeZone,
          items: [{ id: "primary" }],
        }),
        signal: AbortSignal.timeout(20000),
      },
    );
    if (!response.ok)
      throw new Error(
        "Unable to read Calendar. Reconnect Calendar and try again.",
      );
    const data = await response.json();
    if (data.calendars?.primary?.errors?.length)
      throw new Error("Google could not read primary-calendar availability.");
    if ((data.calendars?.primary?.busy ?? []).length > 200)
      throw new Error(
        "Too many calendar intervals. Disconnect Calendar or use a shorter planning window.",
      );
    return {
      time_min: start.toISOString(),
      time_max: end.toISOString(),
      busy: data.calendars?.primary?.busy ?? [],
    };
  }
}
