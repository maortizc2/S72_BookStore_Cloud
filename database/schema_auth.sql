BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS customers (
  customer_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name VARCHAR(120) NOT NULL CHECK (BTRIM(first_name) <> ''),
  last_name VARCHAR(120) NOT NULL CHECK (BTRIM(last_name) <> ''),
  email VARCHAR(320) NOT NULL CHECK (BTRIM(email) <> ''),
  city VARCHAR(120),
  country VARCHAR(120),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customers_active_email_lower
  ON customers (LOWER(BTRIM(email)))
  WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_customers_set_updated_at ON customers;
CREATE TRIGGER trg_customers_set_updated_at
BEFORE UPDATE ON customers
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;
