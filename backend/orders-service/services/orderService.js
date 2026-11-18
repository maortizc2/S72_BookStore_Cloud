import { config } from "../config/env.js";
import { withTransaction } from "../config/database.js";
import { ORDER_STATUSES } from "../config/orders.js";
import { AppError } from "../errors/AppError.js";
import {
  createOrderItem,
  createOrderRecord,
  recalculateOrderTotal,
} from "../repositories/orderRepository.js";

// Synchronous HTTP verification against Auth Service (as shown in architecture diagram)
const verifyCustomerViaAuthService = async (cookieHeader) => {
  const response = await fetch(
    `${config.services.authServiceUrl}${config.api.basePath}/auth/me`,
    {
      method: "GET",
      headers: {
        ...(cookieHeader ? { cookie: cookieHeader } : {}),
      },
    }
  );

  if (!response.ok) {
    throw new AppError(
      "The authenticated customer no longer exists or session is invalid",
      401,
      "INVALID_SESSION"
    );
  }

  const data = await response.json();
  return data.user;
};

// Reserve stock via Books Catalog Service
const reserveBooksViaCatalogService = async (items) => {
  const response = await fetch(
    `${config.services.booksServiceUrl}${config.api.basePath}/books/stock/reserve`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ items }),
    }
  );

  if (!response.ok) {
    let payload = null;
    try {
      payload = await response.json();
    } catch {
      // Ignore JSON parse errors on unexpected responses
    }

    const message = payload?.error?.message ?? "Unable to reserve book stock";
    const code = payload?.error?.code ?? "BOOK_UNAVAILABLE";
    throw new AppError(message, response.status, code);
  }

  const data = await response.json();
  return data.books;
};

export const placeOrder = async ({ customerId, items, cookieHeader }) => {
  await verifyCustomerViaAuthService(cookieHeader);
  const reservedBooks = await reserveBooksViaCatalogService(items);

  return withTransaction(async (client) => {
    const order = await createOrderRecord(
      {
        customerId,
        orderStatus: ORDER_STATUSES.PLACED,
      },
      client
    );

    for (const book of reservedBooks) {
      await createOrderItem(
        {
          orderId: order.order_id,
          bookId: book.book_id,
          isbn: book.isbn,
          title: book.title,
          author: book.author,
          quantity: book.quantity,
          unitPrice: book.price,
        },
        client
      );
    }

    const placedOrder = await recalculateOrderTotal(order.order_id, client);
    const totalQuantity = reservedBooks.reduce(
      (total, item) => total + item.quantity,
      0
    );

    return {
      ...placedOrder,
      total_quantity: totalQuantity,
    };
  });
};
