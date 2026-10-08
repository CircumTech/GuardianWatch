const TOKEN_KEY = "gw_admin_token";
const USER_KEY = "gw_admin_user";

import type { AdminUser } from "./types";

export const adminAuth = {
  getToken: () => localStorage.getItem(TOKEN_KEY),

  getUser: (): AdminUser | null => {
    const raw = localStorage.getItem(USER_KEY);
    return raw ? JSON.parse(raw) : null;
  },

  set: (token: string, user: AdminUser) => {
    localStorage.setItem(TOKEN_KEY, token);
    localStorage.setItem(USER_KEY, JSON.stringify(user));
  },

  clear: () => {
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(USER_KEY);
  },
};