import "dotenv/config";

const REQUIRED_VARIABLES = [
  "NODE_ENV",
  "SERVICE_NAME",
  "PORT",
  "API_BASE_PATH",
  "CORS_ORIGINS",
  "BOOKS_DEFAULT_LIMIT",
  "BOOKS_MAX_LIMIT",
  "HTTP_TRUST_PROXY_HOPS",
  "HTTP_JSON_BODY_LIMIT",
  "ACCESS_LOG_ENABLED",
  "ACCESS_LOG_EXCLUDE_PATHS",
  "ACCESS_LOG_MAX_FIELD_LENGTH",
  "ACCESS_LOG_REQUEST_ID_HEADER",
  "CLICKSTREAM_FILE_ENABLED",
  "CLICKSTREAM_FILE_PATH",
  "DB_HOST",
  "DB_PORT",
  "DB_NAME",
  "DB_USER",
  "DB_PASSWORD",
  "DB_SSL",
  "DB_SSL_REJECT_UNAUTHORIZED",
  "DB_POOL_MAX",
  "DB_IDLE_TIMEOUT_MS",
  "DB_CONNECTION_TIMEOUT_MS",
  "AUTH_JWT_SECRET",
  "AUTH_JWT_ALGORITHM",
  "AUTH_JWT_ISSUER",
  "AUTH_JWT_AUDIENCE",
  "AUTH_TOKEN_TTL_SECONDS",
  "AUTH_COOKIE_NAME",
  "AUTH_COOKIE_SECURE",
  "AUTH_COOKIE_SAME_SITE",
  "AUTH_COOKIE_PATH",
];

const missingVariables = REQUIRED_VARIABLES.filter(
  (name) => process.env[name] === undefined || process.env[name].trim() === ""
);

if (missingVariables.length > 0) {
  throw new Error(
    `Missing required environment variables: ${missingVariables.join(", ")}`
  );
}

const parsePositiveInteger = (name) => {
  const value = Number.parseInt(process.env[name], 10);

  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }

  return value;
};

const parseNonNegativeInteger = (name) => {
  const value = Number.parseInt(process.env[name], 10);

  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }

  return value;
};

const parseBoolean = (name) => {
  const rawValue = process.env[name];

  if (rawValue === undefined || rawValue.trim() === "") {
    throw new Error(`${name} is required`);
  }

  const normalizedValue = rawValue.trim().toLowerCase();

  if (normalizedValue === "true") return true;
  if (normalizedValue === "false") return false;

  throw new Error(`${name} must be either true or false`);
};

const allowedEnvironments = new Set(["development", "test", "production"]);
const environment = process.env.NODE_ENV.trim();

if (!allowedEnvironments.has(environment)) {
  throw new Error("NODE_ENV must be development, test, or production");
}

const apiBasePath = process.env.API_BASE_PATH.trim();

if (!apiBasePath.startsWith("/")) {
  throw new Error("API_BASE_PATH must start with '/'");
}

const booksDefaultLimit = parsePositiveInteger("BOOKS_DEFAULT_LIMIT");
const booksMaxLimit = parsePositiveInteger("BOOKS_MAX_LIMIT");

if (booksDefaultLimit > booksMaxLimit) {
  throw new Error("BOOKS_DEFAULT_LIMIT cannot be greater than BOOKS_MAX_LIMIT");
}

const jwtSecret = process.env.AUTH_JWT_SECRET;

if (jwtSecret.length < 32) {
  throw new Error("AUTH_JWT_SECRET must contain at least 32 characters");
}

const jwtAlgorithm = process.env.AUTH_JWT_ALGORITHM.trim();

if (jwtAlgorithm !== "HS256") {
  throw new Error("AUTH_JWT_ALGORITHM must be HS256");
}

const allowedSameSiteValues = new Set(["lax", "strict", "none"]);
const cookieSameSite = process.env.AUTH_COOKIE_SAME_SITE.trim().toLowerCase();

if (!allowedSameSiteValues.has(cookieSameSite)) {
  throw new Error("AUTH_COOKIE_SAME_SITE must be lax, strict, or none");
}

const cookieSecure = parseBoolean("AUTH_COOKIE_SECURE");

if (cookieSameSite === "none" && !cookieSecure) {
  throw new Error("AUTH_COOKIE_SECURE must be true when AUTH_COOKIE_SAME_SITE is none");
}

const cookiePath = process.env.AUTH_COOKIE_PATH.trim();

if (!cookiePath.startsWith("/")) {
  throw new Error("AUTH_COOKIE_PATH must start with '/'");
}

const corsOrigins = process.env.CORS_ORIGINS.split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

if (corsOrigins.length === 0) {
  throw new Error("CORS_ORIGINS must contain at least one origin");
}

const accessLogExcludedPaths = process.env.ACCESS_LOG_EXCLUDE_PATHS.split(",")
  .map((path) => path.trim())
  .filter(Boolean);

if (accessLogExcludedPaths.length === 0) {
  throw new Error("ACCESS_LOG_EXCLUDE_PATHS must contain at least one path");
}

if (accessLogExcludedPaths.some((path) => !path.startsWith("/"))) {
  throw new Error("Every ACCESS_LOG_EXCLUDE_PATHS value must start with '/'");
}

const requestIdHeader = process.env.ACCESS_LOG_REQUEST_ID_HEADER.trim();

if (!/^[A-Za-z0-9-]+$/.test(requestIdHeader)) {
  throw new Error("ACCESS_LOG_REQUEST_ID_HEADER contains invalid characters");
}

const clickstreamFileEnabled = parseBoolean("CLICKSTREAM_FILE_ENABLED");
const clickstreamFilePath = process.env.CLICKSTREAM_FILE_PATH.trim();

if (clickstreamFileEnabled && !clickstreamFilePath.startsWith("/")) {
  throw new Error("CLICKSTREAM_FILE_PATH must be an absolute path when file logging is enabled");
}

const jsonBodyLimit = process.env.HTTP_JSON_BODY_LIMIT.trim().toLowerCase();

if (!/^\d+(b|kb|mb)$/.test(jsonBodyLimit)) {
  throw new Error("HTTP_JSON_BODY_LIMIT must use a size such as 32768b, 32kb, or 1mb");
}

export const config = Object.freeze({
  app: Object.freeze({
    environment,
    serviceName: process.env.SERVICE_NAME.trim(),
    port: parsePositiveInteger("PORT"),
  }),
  http: Object.freeze({
    trustProxyHops: parseNonNegativeInteger("HTTP_TRUST_PROXY_HOPS"),
    jsonBodyLimit,
  }),
  accessLog: Object.freeze({
    enabled: parseBoolean("ACCESS_LOG_ENABLED"),
    excludedPaths: Object.freeze(accessLogExcludedPaths),
    maxFieldLength: parsePositiveInteger("ACCESS_LOG_MAX_FIELD_LENGTH"),
    requestIdHeader,
  }),
  clickstreamFile: Object.freeze({
    enabled: clickstreamFileEnabled,
    path: clickstreamFilePath,
  }),
  api: Object.freeze({
    basePath: apiBasePath.replace(/\/$/, ""),
    corsOrigins: Object.freeze(corsOrigins),
    books: Object.freeze({
      defaultLimit: booksDefaultLimit,
      maxLimit: booksMaxLimit,
    }),
  }),
  database: Object.freeze({
    host: process.env.DB_HOST.trim(),
    port: parsePositiveInteger("DB_PORT"),
    name: process.env.DB_NAME.trim(),
    user: process.env.DB_USER.trim(),
    password: process.env.DB_PASSWORD,
    ssl: parseBoolean("DB_SSL"),
    sslRejectUnauthorized: parseBoolean("DB_SSL_REJECT_UNAUTHORIZED"),
    poolMax: parsePositiveInteger("DB_POOL_MAX"),
    idleTimeoutMs: parsePositiveInteger("DB_IDLE_TIMEOUT_MS"),
    connectionTimeoutMs: parsePositiveInteger("DB_CONNECTION_TIMEOUT_MS"),
  }),
  auth: Object.freeze({
    jwt: Object.freeze({
      secret: jwtSecret,
      algorithm: jwtAlgorithm,
      issuer: process.env.AUTH_JWT_ISSUER.trim(),
      audience: process.env.AUTH_JWT_AUDIENCE.trim(),
      ttlSeconds: parsePositiveInteger("AUTH_TOKEN_TTL_SECONDS"),
    }),
    cookie: Object.freeze({
      name: process.env.AUTH_COOKIE_NAME.trim(),
      httpOnly: true,
      secure: cookieSecure,
      sameSite: cookieSameSite,
      path: cookiePath,
    }),
  }),
});
