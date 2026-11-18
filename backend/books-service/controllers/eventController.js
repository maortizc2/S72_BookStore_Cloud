import {
  CLIENT_EVENT_TYPES,
  EVENT_FIELD_LIMITS,
  EVENT_SOURCES,
  EVENT_TYPES,
  RESOURCE_TYPES,
} from "../config/events.js";
import { AppError } from "../errors/AppError.js";
import { setBehaviorEvent } from "../middleware/accessLogger.js";

const clientEventTypes = new Set(CLIENT_EVENT_TYPES);
const resourceTypes = new Set(Object.values(RESOURCE_TYPES));

const optionalString = (value, fieldName, maxLength) => {
  if (value === undefined || value === null) {
    return undefined;
  }

  if (typeof value !== "string") {
    throw new AppError(
      `${fieldName} must be a string`,
      400,
      "INVALID_BEHAVIOR_EVENT"
    );
  }

  const normalizedValue = value.trim();

  if (!normalizedValue || normalizedValue.length > maxLength) {
    throw new AppError(
      `${fieldName} is invalid`,
      400,
      "INVALID_BEHAVIOR_EVENT"
    );
  }

  return normalizedValue;
};

const optionalPositiveInteger = (value, fieldName, maxValue) => {
  if (value === undefined || value === null) {
    return undefined;
  }

  if (!Number.isInteger(value) || value <= 0 || value > maxValue) {
    throw new AppError(
      `${fieldName} must be a positive integer no greater than ${maxValue}`,
      400,
      "INVALID_BEHAVIOR_EVENT"
    );
  }

  return value;
};

const requireBookResource = (event) => {
  if (
    event.resourceType !== RESOURCE_TYPES.BOOK ||
    !event.resourceId ||
    !event.isbn
  ) {
    throw new AppError(
      "Book events require resource_type=book, resource_id, and isbn",
      400,
      "INVALID_BEHAVIOR_EVENT"
    );
  }
};

const validateEventSemantics = (event) => {
  switch (event.eventType) {
    case EVENT_TYPES.ADD_TO_CART:
    case EVENT_TYPES.REMOVE_FROM_CART:
    case EVENT_TYPES.CART_QUANTITY_CHANGED:
      requireBookResource(event);

      if (!event.quantity) {
        throw new AppError(
          "Cart events require quantity",
          400,
          "INVALID_BEHAVIOR_EVENT"
        );
      }
      break;

    case EVENT_TYPES.CHECKOUT_STARTED:
      if (!event.quantity) {
        throw new AppError(
          "Checkout events require quantity",
          400,
          "INVALID_BEHAVIOR_EVENT"
        );
      }
      break;

    case EVENT_TYPES.SEARCH:
      if (!event.searchQuery) {
        throw new AppError(
          "Search events require search_query",
          400,
          "INVALID_BEHAVIOR_EVENT"
        );
      }
      break;

    case EVENT_TYPES.RECOMMENDATION_SHOWN:
    case EVENT_TYPES.RECOMMENDATION_CLICKED:
      requireBookResource(event);

      if (!event.recommendationId || !event.position) {
        throw new AppError(
          "Recommendation events require recommendation_id and position",
          400,
          "INVALID_BEHAVIOR_EVENT"
        );
      }
      break;

    default:
      break;
  }
};

export const createBehaviorEvent = async (req, res) => {
  const rawEventType = req.body?.event_type;

  if (typeof rawEventType !== "string" || !clientEventTypes.has(rawEventType)) {
    throw new AppError(
      "event_type is not allowed for client-generated events",
      400,
      "INVALID_BEHAVIOR_EVENT"
    );
  }

  const resourceType = optionalString(
    req.body?.resource_type,
    "resource_type",
    EVENT_FIELD_LIMITS.resourceType
  );

  if (resourceType && !resourceTypes.has(resourceType)) {
    throw new AppError(
      "resource_type is invalid",
      400,
      "INVALID_BEHAVIOR_EVENT"
    );
  }

  const event = {
    eventType: rawEventType,
    eventSource: EVENT_SOURCES.CLIENT,
    resourceType,
    resourceId: optionalString(
      req.body?.resource_id,
      "resource_id",
      EVENT_FIELD_LIMITS.resourceId
    ),
    isbn: optionalString(
      req.body?.isbn,
      "isbn",
      EVENT_FIELD_LIMITS.isbn
    ),
    recommendationId: optionalString(
      req.body?.recommendation_id,
      "recommendation_id",
      EVENT_FIELD_LIMITS.recommendationId
    ),
    modelVersion: optionalString(
      req.body?.model_version,
      "model_version",
      EVENT_FIELD_LIMITS.modelVersion
    ),
    experimentId: optionalString(
      req.body?.experiment_id,
      "experiment_id",
      EVENT_FIELD_LIMITS.experimentId
    ),
    position: optionalPositiveInteger(
      req.body?.position,
      "position",
      EVENT_FIELD_LIMITS.position
    ),
    quantity: optionalPositiveInteger(
      req.body?.quantity,
      "quantity",
      EVENT_FIELD_LIMITS.quantity
    ),
    searchQuery: optionalString(
      req.body?.search_query,
      "search_query",
      EVENT_FIELD_LIMITS.searchQuery
    ),
  };

  validateEventSemantics(event);
  setBehaviorEvent(req, event);

  res.set("Cache-Control", "no-store");
  res.status(204).send();
};
