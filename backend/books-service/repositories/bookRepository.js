import { pool } from "../config/database.js";

const BOOK_COLUMNS = `
  book_id,
  isbn,
  title,
  author,
  description,
  category,
  publisher,
  publication_year,
  price,
  stock,
  image,
  created_at,
  updated_at
`;

export const findBooks = async ({ limit, offset }, executor = pool) => {
  const query = `
    SELECT ${BOOK_COLUMNS}
    FROM books
    WHERE deleted_at IS NULL
    ORDER BY title ASC
    LIMIT $1 OFFSET $2
  `;

  const { rows } = await executor.query(query, [limit, offset]);
  return rows;
};

export const findBookByIsbn = async (isbn, executor = pool) => {
  const query = `
    SELECT ${BOOK_COLUMNS}
    FROM books
    WHERE isbn = $1
      AND deleted_at IS NULL
    LIMIT 1
  `;

  const { rows } = await executor.query(query, [isbn]);
  return rows[0] ?? null;
};

export const findBooksByIdsForUpdate = async (bookIds, executor) => {
  const query = `
    SELECT
      book_id,
      isbn,
      title,
      author,
      price,
      stock
    FROM books
    WHERE book_id = ANY($1::uuid[])
      AND deleted_at IS NULL
    ORDER BY book_id
    FOR UPDATE
  `;

  const { rows } = await executor.query(query, [bookIds]);
  return rows;
};

export const decreaseBookStock = async (
  { bookId, quantity },
  executor
) => {
  const query = `
    UPDATE books
    SET stock = stock - $2
    WHERE book_id = $1
      AND deleted_at IS NULL
      AND stock >= $2
    RETURNING stock
  `;

  const { rows } = await executor.query(query, [bookId, quantity]);
  return rows[0] ?? null;
};
