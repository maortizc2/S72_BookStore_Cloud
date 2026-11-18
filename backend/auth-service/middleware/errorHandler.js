import { logger } from "../config/logger.js";

export const notFoundHandler = (req, res) => {
  res.status(404).json({
    error: {
      code: "RESOURCE_NOT_FOUND",
      message: "The requested resource was not found",
    },
  });
};

export const errorHandler = (err, req, res, next) => {
  void next;

  const statusCode = err.statusCode ?? 500;
  const code = err.code ?? "INTERNAL_SERVER_ERROR";
  const logMetadata = {
    method: req.method,
    path: req.originalUrl,
    statusCode,
    code,
    errorName: err.name,
  };

  if (statusCode >= 500) {
    logger.error("Request failed", logMetadata);
  } else {
    logger.info("Request rejected", logMetadata);
  }

  res.status(statusCode).json({
    error: {
      code,
      message: statusCode >= 500 ? "Internal Server Error" : err.message,
    },
  });
};
