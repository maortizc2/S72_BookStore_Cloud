import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";

import { config } from "../config/env.js";
import { EVENT_SCHEMA_VERSION } from "../config/events.js";
import { writeClickstreamLine } from "../logging/clickstreamFileWriter.js";

const MONTH_NAMES = Object.freeze([
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
]);

const EMPTY_VALUE = "-";

const trimToMaxLength = (value) =>
  value.length <= config.accessLog.maxFieldLength
    ? value
    : value.slice(0, config.accessLog.maxFieldLength);

const normalizeLogValue = (value) => {
  if (value === undefined || value === null || value === "") {
    return EMPTY_VALUE;
  }

  return trimToMaxLength(String(value).replace(/[\r\n\t]/g, " "));
};

const escapeQuotedValue = (value) =>
  normalizeLogValue(value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"');

const encodeContextValue = (value) => {
  const normalizedValue = normalizeLogValue(value);

  if (normalizedValue === EMPTY_VALUE) {
    return EMPTY_VALUE;
  }

  const encodedValue = encodeURIComponent(normalizedValue);

  if (encodedValue.length <= config.accessLog.maxFieldLength) {
    return encodedValue;
  }

  let truncatedValue = encodedValue.slice(0, config.accessLog.maxFieldLength);
  const lastPercentIndex = truncatedValue.lastIndexOf("%");

  if (lastPercentIndex >= truncatedValue.length - 2) {
    truncatedValue = truncatedValue.slice(0, lastPercentIndex);
  }

  return truncatedValue || EMPTY_VALUE;
};

const formatAccessTimestamp = (date) => {
  const day = String(date.getUTCDate()).padStart(2, "0");
  const month = MONTH_NAMES[date.getUTCMonth()];
  const year = date.getUTCFullYear();
  const hours = String(date.getUTCHours()).padStart(2, "0");
  const minutes = String(date.getUTCMinutes()).padStart(2, "0");
  const seconds = String(date.getUTCSeconds()).padStart(2, "0");

  return `${day}/${month}/${year}:${hours}:${minutes}:${seconds} +0000`;
};

const normalizeClientIp = (ip) => {
  const normalizedIp = normalizeLogValue(ip);

  if (normalizedIp.startsWith("::ffff:")) {
    return normalizedIp.slice(7);
  }

  return normalizedIp;
};

const getResponseSize = (res) => {
  const contentLength = res.getHeader("content-length");
  return normalizeLogValue(contentLength);
};

const getEventContext = (req) => ({
  eventId: req.behaviorEvent?.eventId,
  eventType: req.behaviorEvent?.eventType,
  eventSource: req.behaviorEvent?.eventSource,
  resourceType: req.behaviorEvent?.resourceType,
  resourceId: req.behaviorEvent?.resourceId,
  isbn: req.behaviorEvent?.isbn,
  recommendationId: req.behaviorEvent?.recommendationId,
  modelVersion: req.behaviorEvent?.modelVersion,
  experimentId: req.behaviorEvent?.experimentId,
  position: req.behaviorEvent?.position,
  quantity: req.behaviorEvent?.quantity,
  searchQuery: req.behaviorEvent?.searchQuery,
  orderId: req.behaviorEvent?.orderId,
});

const buildContextSection = ({ req, latencyMs }) => {
  const event = getEventContext(req);

  return [
    `schema_version=${EVENT_SCHEMA_VERSION}`,
    `request_id=${encodeContextValue(req.requestId)}`,
    `session_id=${encodeContextValue(req.auth?.sessionId)}`,
    `event_id=${encodeContextValue(event.eventId)}`,
    `event_type=${encodeContextValue(event.eventType)}`,
    `event_source=${encodeContextValue(event.eventSource)}`,
    `resource_type=${encodeContextValue(event.resourceType)}`,
    `resource_id=${encodeContextValue(event.resourceId)}`,
    `isbn=${encodeContextValue(event.isbn)}`,
    `recommendation_id=${encodeContextValue(event.recommendationId)}`,
    `model_version=${encodeContextValue(event.modelVersion)}`,
    `experiment_id=${encodeContextValue(event.experimentId)}`,
    `position=${encodeContextValue(event.position)}`,
    `quantity=${encodeContextValue(event.quantity)}`,
    `search_query=${encodeContextValue(event.searchQuery)}`,
    `order_id=${encodeContextValue(event.orderId)}`,
    `latency_ms=${encodeContextValue(latencyMs)}`,
  ].join(" ");
};

const writeAccessLog = ({ req, res, startedAt, startedPerformance }) => {
  const latencyMs = Math.max(0, Math.round(performance.now() - startedPerformance));
  const remoteUser = normalizeLogValue(req.auth?.customerId);
  const requestLine = `${req.method} ${req.originalUrl} HTTP/${req.httpVersion}`;
  const referrer = req.get("referer") ?? EMPTY_VALUE;
  const userAgent = req.get("user-agent") ?? EMPTY_VALUE;
  const context = buildContextSection({ req, latencyMs });

  const line = [
    normalizeClientIp(req.ip),
    EMPTY_VALUE,
    remoteUser,
    `[${formatAccessTimestamp(startedAt)}]`,
    `"${escapeQuotedValue(requestLine)}"`,
    res.statusCode,
    getResponseSize(res),
    `"${escapeQuotedValue(referrer)}"`,
    `"${escapeQuotedValue(userAgent)}"`,
    `"${context}"`,
  ].join(" ");

  process.stdout.write(`${line}\n`);
  writeClickstreamLine(line);
};

export const setBehaviorEvent = (req, event) => {
  req.behaviorEvent = Object.freeze({
    eventId: randomUUID(),
    eventType: event.eventType,
    eventSource: event.eventSource,
    resourceType: event.resourceType,
    resourceId: event.resourceId,
    isbn: event.isbn,
    recommendationId: event.recommendationId,
    modelVersion: event.modelVersion,
    experimentId: event.experimentId,
    position: event.position,
    quantity: event.quantity,
    searchQuery: event.searchQuery,
    orderId: event.orderId,
  });
};

export const accessLogger = (req, res, next) => {
  if (
    !config.accessLog.enabled ||
    config.accessLog.excludedPaths.includes(req.path)
  ) {
    next();
    return;
  }

  const startedAt = new Date();
  const startedPerformance = performance.now();

  req.requestId = randomUUID();
  res.set(config.accessLog.requestIdHeader, req.requestId);

  res.once("finish", () => {
    writeAccessLog({ req, res, startedAt, startedPerformance });
  });

  next();
};
