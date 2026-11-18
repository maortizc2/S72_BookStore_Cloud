import { AppError } from "../errors/AppError.js";

export const authenticate = async (req, res, next) => {
  void res;

  if (req.auth) {
    next();
    return;
  }

  if (req.authState === "invalid") {
    throw new AppError(
      "The session is invalid or has expired",
      401,
      "INVALID_SESSION"
    );
  }

  throw new AppError("Authentication is required", 401, "AUTH_REQUIRED");
};
