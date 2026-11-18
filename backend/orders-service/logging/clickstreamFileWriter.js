import { mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { createWriteStream } from "node:fs";

import { config } from "../config/env.js";
import { logger } from "../config/logger.js";

let stream = null;
let fileAvailable = false;

export const initializeClickstreamFileWriter = async () => {
  if (!config.clickstreamFile.enabled) {
    return;
  }

  const directory = dirname(config.clickstreamFile.path);
  await mkdir(directory, { recursive: true });

  stream = createWriteStream(config.clickstreamFile.path, {
    flags: "a",
    encoding: "utf8",
  });

  await new Promise((resolve, reject) => {
    const handleOpen = () => {
      cleanup();
      fileAvailable = true;
      resolve();
    };

    const handleError = (error) => {
      cleanup();
      reject(error);
    };

    const cleanup = () => {
      stream.off("open", handleOpen);
      stream.off("error", handleError);
    };

    stream.once("open", handleOpen);
    stream.once("error", handleError);
  });

  stream.on("error", (error) => {
    fileAvailable = false;
    logger.error("Clickstream file writer failed", {
      path: config.clickstreamFile.path,
      error: error.message,
    });
  });

  logger.info("Clickstream file writer initialized", {
    path: config.clickstreamFile.path,
  });
};

export const writeClickstreamLine = (line) => {
  if (!config.clickstreamFile.enabled || !stream || !fileAvailable) {
    return;
  }

  stream.write(`${line}\n`);
};

export const closeClickstreamFileWriter = async () => {
  if (!stream) {
    return;
  }

  const streamToClose = stream;
  stream = null;
  fileAvailable = false;

  await new Promise((resolve) => {
    streamToClose.end(resolve);
  });
};
