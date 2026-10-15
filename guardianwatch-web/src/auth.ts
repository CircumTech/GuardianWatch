import type { AdminUser } from "./types";

const TOKEN_KEY = "gw_admin_token";
const USER_KEY = "gw_admin_user";

// sessionStorage: token lifetime is bounded by the browser tab.
// Closing the tab ends the session. XSS can still read it while the
// tab is open, but the exposure window is far smaller than
// localStorage's indefinite persistence.
export const adminAuth = {
  getToken: () => sessionStorage.getItem(TOKEN_KEY),

  getUser: (): AdminUser | null => {
    const raw = sessionStorage.getItem(USER_KEY);
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  },

  set: (token: string, user: AdminUser) => {
    sessionStorage.setItem(TOKEN_KEY, token);
    sessionStorage.setItem(USER_KEY, JSON.stringify(user));
  },

  clear: () => {
    sessionStorage.removeItem(TOKEN_KEY);
    sessionStorage.removeItem(USER_KEY);
  },
};