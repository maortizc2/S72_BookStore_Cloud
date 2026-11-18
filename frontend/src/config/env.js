const requiredValue = (name) => {
  const value = import.meta.env[name]?.trim();

  if (!value) {
    throw new Error(`Missing required frontend environment variable: ${name}`);
  }

  return value;
};

const normalizeBaseUrl = (value) => {
  if (value === "/") {
    return value;
  }

  return value.replace(/\/+$/, "");
};

const normalizePrefix = (value, name) => {
  if (!value.startsWith("/")) {
    throw new Error(`${name} must start with '/'`);
  }

  return value.replace(/\/$/, "");
};

export const frontendConfig = Object.freeze({
  apiBaseUrl: normalizeBaseUrl(requiredValue("VITE_API_BASE_URL")),
  apiPrefix: normalizePrefix(requiredValue("VITE_API_PREFIX"), "VITE_API_PREFIX"),
  currency: Object.freeze({
    locale: requiredValue("VITE_CURRENCY_LOCALE"),
    code: requiredValue("VITE_CURRENCY_CODE"),
  }),
});
