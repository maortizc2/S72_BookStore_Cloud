import pg from "pg";
import { config } from "./env.js";

const { Pool } = pg;

export const pool = new Pool({
  host: config.database.host,
  port: config.database.port,
  database: config.database.name,
  user: config.database.user,
  password: config.database.password,
  ssl: config.database.ssl ? { rejectUnauthorized: config.database.sslRejectUnauthorized, } : false,
  max: config.database.poolMax,
  idleTimeoutMillis: config.database.idleTimeoutMs,
  connectionTimeoutMillis: config.database.connectionTimeoutMs,
});

export const withTransaction = async (operation) => {
  const client = await pool.connect();

  try {
    await client.query("BEGIN");
    const result = await operation(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch {
      // Preserve the original transactional error.
    }

    throw error;
  } finally {
    client.release();
  }
};

export const verifyDatabaseConnection = async () => {
  await pool.query("SELECT 1");
};

export const closeDatabaseConnection = async () => {
  await pool.end();
};
