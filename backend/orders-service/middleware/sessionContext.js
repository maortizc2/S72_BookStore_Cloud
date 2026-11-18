import { parse } from "cookie";

import { config } from "../config/env.js";
import { verifySessionToken } from "../services/authService.js";

export const sessionContext = async (req, res, next) => {
  void res;

  req.auth = undefined;
  req.authState = "anonymous";

  const cookies = parse(req.headers.cookie ?? "");
  const token = cookies[config.auth.cookie.name];

  if (!token) {
    next();
    return;
  }

  try {
    req.auth = await verifySessionToken(token);
    req.authState = "authenticated";
  } catch {
    req.authState = "invalid";
  }

  next();
};
