import { pool } from "../config/database.js";

const CUSTOMER_COLUMNS = `
  customer_id,
  first_name,
  last_name,
  email,
  city,
  country,
  created_at,
  updated_at
`;

export const findCustomerByEmail = async (email, executor = pool) => {
  const query = `
    SELECT ${CUSTOMER_COLUMNS}
    FROM customers
    WHERE LOWER(BTRIM(email)) = LOWER(BTRIM($1))
      AND deleted_at IS NULL
    LIMIT 1
  `;

  const { rows } = await executor.query(query, [email]);
  return rows[0] ?? null;
};

export const findCustomerById = async (customerId, executor = pool) => {
  const query = `
    SELECT ${CUSTOMER_COLUMNS}
    FROM customers
    WHERE customer_id = $1
      AND deleted_at IS NULL
    LIMIT 1
  `;

  const { rows } = await executor.query(query, [customerId]);
  return rows[0] ?? null;
};
