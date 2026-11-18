import { randomUUID } from "node:crypto";
import { jwtVerify, SignJWT } from "jose";

import { config } from "../config/env.js";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const secretKey = new TextEncoder().encode(config.auth.jwt.secret);

export const createSessionToken = async (customerId) => {
  const sessionId = randomUUID();

  const token = await new SignJWT({ sid: sessionId })
    .setProtectedHeader({ alg: config.auth.jwt.algorithm, typ: "JWT" })
    .setSubject(customerId)
    .setIssuer(config.auth.jwt.issuer)
    .setAudience(config.auth.jwt.audience)
    .setIssuedAt()
    .setExpirationTime(`${config.auth.jwt.ttlSeconds}s`)
    .sign(secretKey);

  return { token, sessionId };
};

export const verifySessionToken = async (token) => {
  const { payload } = await jwtVerify(token, secretKey, {
    issuer: config.auth.jwt.issuer,
    audience: config.auth.jwt.audience,
    algorithms: [config.auth.jwt.algorithm],
  });

  if (
    typeof payload.sub !== "string" ||
    typeof payload.sid !== "string" ||
    !UUID_PATTERN.test(payload.sub) ||
    !UUID_PATTERN.test(payload.sid)
  ) {
    throw new Error("Session token is missing valid identity claims");
  }

  return {
    customerId: payload.sub,
    sessionId: payload.sid,
  };
};
