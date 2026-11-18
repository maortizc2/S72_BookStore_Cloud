INSERT INTO customers (
  customer_id, first_name, last_name, email, city, country
)
VALUES
  ('00000000-0000-4000-8000-000000000001', 'Ana', 'Rojas', 'synthetic.customer.0001@bookstore.test', 'Medellín', 'Colombia'),
  ('00000000-0000-4000-8000-000000000002', 'Carlos', 'Gómez', 'synthetic.customer.0002@bookstore.test', 'Bogotá', 'Colombia'),
  ('00000000-0000-4000-8000-000000000003', 'Laura', 'Mejía', 'synthetic.customer.0003@bookstore.test', 'Cali', 'Colombia'),
  ('00000000-0000-4000-8000-000000000004', 'Andrés', 'Restrepo', 'synthetic.customer.0004@bookstore.test', 'Medellín', 'Colombia'),
  ('00000000-0000-4000-8000-000000000005', 'Mariana', 'López', 'synthetic.customer.0005@bookstore.test', 'Barranquilla', 'Colombia'),
  ('00000000-0000-4000-8000-000000000006', 'Santiago', 'Vélez', 'synthetic.customer.0006@bookstore.test', 'Pereira', 'Colombia'),
  ('00000000-0000-4000-8000-000000000007', 'Valentina', 'Ortiz', 'synthetic.customer.0007@bookstore.test', 'Manizales', 'Colombia'),
  ('00000000-0000-4000-8000-000000000008', 'Daniel', 'Ramírez', 'synthetic.customer.0008@bookstore.test', 'Medellín', 'Colombia')
ON CONFLICT DO NOTHING;
