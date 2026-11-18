import { config } from "../config/env.js";
import { withTransaction } from "../config/database.js";
import {
  EVENT_SOURCES,
  EVENT_TYPES,
  RESOURCE_TYPES,
} from "../config/events.js";
import { AppError } from "../errors/AppError.js";
import { setBehaviorEvent } from "../middleware/accessLogger.js";
import {
  decreaseBookStock,
  findBookByIsbn,
  findBooks,
  findBooksByIdsForUpdate,
} from "../repositories/bookRepository.js";

const parseNonNegativeInteger = (rawValue, parameterName) => {
  const value = Number.parseInt(rawValue, 10);

  if (!Number.isInteger(value) || value < 0) {
    throw new AppError(
      `${parameterName} must be a non-negative integer`,
      400,
      "INVALID_QUERY_PARAMETER"
    );
  }

  return value;
};

export const getBooks = async (req, res) => {
  const requestedLimit = req.query.limit
    ? parseNonNegativeInteger(req.query.limit, "limit")
    : config.api.books.defaultLimit;

  if (requestedLimit === 0 || requestedLimit > config.api.books.maxLimit) {
    throw new AppError(
      `limit must be between 1 and ${config.api.books.maxLimit}`,
      400,
      "INVALID_QUERY_PARAMETER"
    );
  }

  const offset = req.query.offset
    ? parseNonNegativeInteger(req.query.offset, "offset")
    : 0;

  const books = await findBooks({ limit: requestedLimit, offset });

  setBehaviorEvent(req, {
    eventType: EVENT_TYPES.CATALOG_VIEW,
    eventSource: EVENT_SOURCES.HTTP,
    resourceType: RESOURCE_TYPES.CATALOG,
  });

  res.status(200).json(books);
};

export const getBookByIsbn = async (req, res) => {
  const isbn = req.params.isbn?.trim();

  if (!isbn) {
    throw new AppError("ISBN is required", 400, "INVALID_ISBN");
  }

  const book = await findBookByIsbn(isbn);

  if (!book) {
    throw new AppError("Book not found", 404, "BOOK_NOT_FOUND");
  }

  setBehaviorEvent(req, {
    eventType: EVENT_TYPES.BOOK_VIEW,
    eventSource: EVENT_SOURCES.HTTP,
    resourceType: RESOURCE_TYPES.BOOK,
    resourceId: book.book_id,
    isbn: book.isbn,
  });

  res.status(200).json(book);
};

// Internal synchronous HTTP endpoint called by Orders Service to verify & reserve stock
export const reserveBookStock = async (req, res) => {
  const rawItems = req.body?.items;

  if (!Array.isArray(rawItems) || rawItems.length === 0) {
    throw new AppError("Items are required to reserve stock", 400, "INVALID_ORDER");
  }

  const orderedItems = [...rawItems].sort((a, b) =>
    String(a.bookId).localeCompare(String(b.bookId))
  );
  const bookIds = orderedItems.map((item) => item.bookId);

  const reservedBooks = await withTransaction(async (client) => {
    const books = await findBooksByIdsForUpdate(bookIds, client);

    if (books.length !== orderedItems.length) {
      throw new AppError(
        "One or more books are no longer available",
        409,
        "BOOK_UNAVAILABLE"
      );
    }

    const booksById = new Map(books.map((book) => [book.book_id, book]));
    const result = [];

    for (const item of orderedItems) {
      const book = booksById.get(item.bookId);

      if (!book) {
        throw new AppError(
          "One or more books are no longer available",
          409,
          "BOOK_UNAVAILABLE"
        );
      }

      if (book.stock < item.quantity) {
        throw new AppError(
          `Insufficient stock for ${book.title}`,
          409,
          "INSUFFICIENT_STOCK"
        );
      }

      const updatedBook = await decreaseBookStock(
        {
          bookId: book.book_id,
          quantity: item.quantity,
        },
        client
      );

      if (!updatedBook) {
        throw new AppError(
          `Insufficient stock for ${book.title}`,
          409,
          "INSUFFICIENT_STOCK"
        );
      }

      result.push({
        book_id: book.book_id,
        isbn: book.isbn,
        title: book.title,
        author: book.author,
        price: book.price,
        quantity: item.quantity,
      });
    }

    return result;
  });

  res.status(200).json({ books: reservedBooks });
};
