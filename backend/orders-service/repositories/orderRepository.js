import { pool } from "../config/database.js";

export const createOrderRecord = async (
  { customerId, orderStatus },
  executor
) => {
  const query = `
    INSERT INTO orders (
      customer_id,
      order_status,
      total_amount
    )
    VALUES ($1, $2, 0)
    RETURNING
      order_id,
      customer_id,
      order_status,
      total_amount,
      order_timestamp
  `;

  const { rows } = await executor.query(query, [customerId, orderStatus]);
  return rows[0];
};

export const createOrderItem = async (
  { orderId, bookId, isbn, title, author, quantity, unitPrice },
  executor
) => {
  const query = `
    INSERT INTO order_items (
      order_id,
      book_id,
      isbn,
      title,
      author,
      quantity,
      unit_price
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    RETURNING
      order_item_id,
      order_id,
      book_id,
      isbn,
      title,
      author,
      quantity,
      unit_price,
      line_total
  `;

  const { rows } = await executor.query(query, [
    orderId,
    bookId,
    isbn,
    title,
    author,
    quantity,
    unitPrice,
  ]);

  return rows[0];
};

export const recalculateOrderTotal = async (orderId, executor) => {
  const query = `
    UPDATE orders
    SET total_amount = (
      SELECT COALESCE(SUM(line_total), 0)
      FROM order_items
      WHERE order_id = $1
    )
    WHERE order_id = $1
    RETURNING
      order_id,
      customer_id,
      order_status,
      total_amount,
      order_timestamp
  `;

  const { rows } = await executor.query(query, [orderId]);
  return rows[0];
};

export const findOrdersByCustomerId = async (
  customerId,
  executor = pool
) => {
  const query = `
    SELECT
      o.order_id,
      o.order_status,
      o.total_amount,
      o.order_timestamp,
      COALESCE(SUM(oi.quantity), 0)::INTEGER AS total_quantity
    FROM orders o
    LEFT JOIN order_items oi
      ON oi.order_id = o.order_id
    WHERE o.customer_id = $1
      AND o.deleted_at IS NULL
    GROUP BY
      o.order_id,
      o.order_status,
      o.total_amount,
      o.order_timestamp
    ORDER BY
      o.order_timestamp DESC,
      o.order_id DESC
  `;

  const { rows } = await executor.query(query, [customerId]);
  return rows;
};

export const findOrderByIdForCustomer = async (
  { orderId, customerId },
  executor = pool
) => {
  const query = `
    SELECT
      o.order_id,
      o.order_status,
      o.total_amount,
      o.order_timestamp,
      COALESCE(SUM(oi.quantity), 0)::INTEGER AS total_quantity
    FROM orders o
    LEFT JOIN order_items oi
      ON oi.order_id = o.order_id
    WHERE o.order_id = $1
      AND o.customer_id = $2
      AND o.deleted_at IS NULL
    GROUP BY
      o.order_id,
      o.order_status,
      o.total_amount,
      o.order_timestamp
    LIMIT 1
  `;

  const { rows } = await executor.query(query, [orderId, customerId]);
  return rows[0] ?? null;
};

export const findOrderItemsByOrderId = async (
  orderId,
  executor = pool
) => {
  const query = `
    SELECT
      oi.order_item_id,
      oi.book_id,
      oi.isbn,
      oi.title,
      oi.author,
      oi.quantity,
      oi.unit_price,
      oi.line_total
    FROM order_items oi
    WHERE oi.order_id = $1
    ORDER BY
      oi.created_at ASC,
      oi.order_item_id ASC
  `;

  const { rows } = await executor.query(query, [orderId]);
  return rows;
};
