import { config } from "../config/env.js";
import {
  EVENT_SOURCES,
  EVENT_TYPES,
  RESOURCE_TYPES,
} from "../config/events.js";
import { AppError } from "../errors/AppError.js";
import { setBehaviorEvent } from "../middleware/accessLogger.js";
import {
  findOrderByIdForCustomer,
  findOrderItemsByOrderId,
  findOrdersByCustomerId,
} from "../repositories/orderRepository.js";
import { placeOrder } from "../services/orderService.js";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const normalizeItems = (rawItems) => {
  if (!Array.isArray(rawItems) || rawItems.length === 0) {
    throw new AppError(
      "The order must contain at least one item",
      400,
      "INVALID_ORDER"
    );
  }

  if (rawItems.length > config.api.orders.maxDistinctItems) {
    throw new AppError(
      `The order cannot contain more than ${config.api.orders.maxDistinctItems} distinct items`,
      400,
      "INVALID_ORDER"
    );
  }

  const seenBookIds = new Set();

  return rawItems.map((rawItem) => {
    if (!rawItem || typeof rawItem !== "object" || Array.isArray(rawItem)) {
      throw new AppError("Every order item is invalid", 400, "INVALID_ORDER");
    }

    if (typeof rawItem.book_id !== "string") {
      throw new AppError("book_id is invalid", 400, "INVALID_ORDER");
    }

    const bookId = rawItem.book_id.trim().toLowerCase();

    if (!bookId || !UUID_PATTERN.test(bookId)) {
      throw new AppError("book_id is invalid", 400, "INVALID_ORDER");
    }

    if (seenBookIds.has(bookId)) {
      throw new AppError(
        "The same book cannot appear more than once in an order",
        400,
        "INVALID_ORDER"
      );
    }

    seenBookIds.add(bookId);

    if (
      !Number.isInteger(rawItem.quantity) ||
      rawItem.quantity <= 0 ||
      rawItem.quantity > config.api.orders.maxQuantityPerItem
    ) {
      throw new AppError(
        `quantity must be an integer between 1 and ${config.api.orders.maxQuantityPerItem}`,
        400,
        "INVALID_ORDER"
      );
    }

    return {
      bookId,
      quantity: rawItem.quantity,
    };
  });
};

const normalizeOrderId = (rawOrderId) => {
  if (typeof rawOrderId !== "string") {
    throw new AppError("orderId is invalid", 400, "INVALID_ORDER_ID");
  }

  const orderId = rawOrderId.trim().toLowerCase();

  if (!UUID_PATTERN.test(orderId)) {
    throw new AppError("orderId is invalid", 400, "INVALID_ORDER_ID");
  }

  return orderId;
};

const toPublicOrderSummary = (order) => ({
  orderId: order.order_id,
  status: order.order_status,
  totalAmount: order.total_amount,
  orderTimestamp: order.order_timestamp,
  totalQuantity: order.total_quantity,
});

const toPublicOrderItem = (item) => ({
  orderItemId: item.order_item_id,
  bookId: item.book_id,
  isbn: item.isbn,
  title: item.title,
  author: item.author,
  quantity: item.quantity,
  unitPrice: item.unit_price,
  lineTotal: item.line_total,
});

const disableResponseCaching = (res) => {
  res.set("Cache-Control", "no-store");
};

export const createOrder = async (req, res) => {
  const items = normalizeItems(req.body?.items);
  const order = await placeOrder({
    customerId: req.auth.customerId,
    items,
    cookieHeader: req.headers.cookie,
  });

  setBehaviorEvent(req, {
    eventType: EVENT_TYPES.PURCHASE,
    eventSource: EVENT_SOURCES.HTTP,
    resourceType: RESOURCE_TYPES.ORDER,
    resourceId: order.order_id,
    orderId: order.order_id,
    quantity: order.total_quantity,
  });

  disableResponseCaching(res);
  res.status(201).json({
    order: toPublicOrderSummary(order),
  });
};

export const getOrders = async (req, res) => {
  const orders = await findOrdersByCustomerId(req.auth.customerId);

  disableResponseCaching(res);
  res.status(200).json({
    orders: orders.map(toPublicOrderSummary),
  });
};

export const getOrderById = async (req, res) => {
  const orderId = normalizeOrderId(req.params.orderId);
  const order = await findOrderByIdForCustomer({
    orderId,
    customerId: req.auth.customerId,
  });

  if (!order) {
    throw new AppError("Order not found", 404, "ORDER_NOT_FOUND");
  }

  const items = await findOrderItemsByOrderId(orderId);

  disableResponseCaching(res);
  res.status(200).json({
    order: {
      ...toPublicOrderSummary(order),
      items: items.map(toPublicOrderItem),
    },
  });
};
