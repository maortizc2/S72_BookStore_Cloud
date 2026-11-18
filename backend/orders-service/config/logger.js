import { config } from "./env.js";

const writeLog = (level, message, metadata = {}) => {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    service: config.app.serviceName,
    environment: config.app.environment,
    message,
    ...metadata,
  };

  const serializedEntry = JSON.stringify(entry);

  if (level === "error") {
    console.error(serializedEntry);
    return;
  }

  console.log(serializedEntry);
};

export const logger = Object.freeze({
  info: (message, metadata) => writeLog("info", message, metadata),
  error: (message, metadata) => writeLog("error", message, metadata),
});
