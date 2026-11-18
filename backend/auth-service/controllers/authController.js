import { config } from "../config/env.js";
import {
  EVENT_SOURCES,
  EVENT_TYPES,
  RESOURCE_TYPES,
} from "../config/events.js";
import { AppError } from "../errors/AppError.js";
import { setBehaviorEvent } from "../middleware/accessLogger.js";
import {
  findCustomerByEmail,
  findCustomerById,
} from "../repositories/customerRepository.js";
import { createSessionToken } from "../services/authService.js";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+$/;

const SESSION_COOKIE_OPTIONS = Object.freeze({
  httpOnly: config.auth.cookie.httpOnly,
  secure: config.auth.cookie.secure,
  sameSite: config.auth.cookie.sameSite,
  path: config.auth.cookie.path,
});

const toPublicCustomer = (customer) => ({
  customerId: customer.customer_id,
  firstName: customer.first_name,
  lastName: customer.last_name,
  email: customer.email,
  city: customer.city,
  country: customer.country,
});

const normalizeEmail = (rawEmail) => {
  if (typeof rawEmail !== "string") {
    throw new AppError("Email is required", 400, "INVALID_EMAIL");
  }

  const email = rawEmail.trim();

  if (!email || email.length > 320 || !EMAIL_PATTERN.test(email)) {
    throw new AppError("Email is invalid", 400, "INVALID_EMAIL");
  }

  return email;
};

const disableResponseCaching = (res) => {
  res.set("Cache-Control", "no-store");
};

export const login = async (req, res) => {
  const email = normalizeEmail(req.body?.email);
  const customer = await findCustomerByEmail(email);

  if (!customer) {
    throw new AppError(
      "Unable to sign in with the provided email",
      401,
      "INVALID_LOGIN"
    );
  }

  const { token, sessionId } = await createSessionToken(customer.customer_id);

  req.auth = {
    customerId: customer.customer_id,
    sessionId,
  };
  req.authState = "authenticated";

  setBehaviorEvent(req, {
    eventType: EVENT_TYPES.LOGIN,
    eventSource: EVENT_SOURCES.HTTP,
    resourceType: RESOURCE_TYPES.CUSTOMER,
    resourceId: customer.customer_id,
  });

  res.cookie(config.auth.cookie.name, token, {
    ...SESSION_COOKIE_OPTIONS,
    maxAge: config.auth.jwt.ttlSeconds * 1000,
  });

  disableResponseCaching(res);
  res.status(200).json({
    user: toPublicCustomer(customer),
  });
};

export const getCurrentUser = async (req, res) => {
  const customer = await findCustomerById(req.auth.customerId);

  if (!customer) {
    res.clearCookie(config.auth.cookie.name, SESSION_COOKIE_OPTIONS);
    throw new AppError(
      "The authenticated customer no longer exists",
      401,
      "INVALID_SESSION"
    );
  }

  disableResponseCaching(res);
  res.status(200).json({
    user: toPublicCustomer(customer),
  });
};

export const logout = async (req, res) => {
  if (req.auth) {
    setBehaviorEvent(req, {
      eventType: EVENT_TYPES.LOGOUT,
      eventSource: EVENT_SOURCES.HTTP,
      resourceType: RESOURCE_TYPES.CUSTOMER,
      resourceId: req.auth.customerId,
    });
  }

  res.clearCookie(config.auth.cookie.name, SESSION_COOKIE_OPTIONS);
  disableResponseCaching(res);
  res.status(204).send();
};
