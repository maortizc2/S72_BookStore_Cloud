INSERT INTO books (
  book_id, isbn, title, author, description, category, publisher,
  publication_year, price, stock, image
)
VALUES
  ('00000000-0000-4000-9000-000000000001', '9781491950357', 'Designing Data-Intensive Applications', 'Martin Kleppmann', 'Principles and practical techniques for building reliable, scalable, and maintainable data systems.', 'Data Systems', 'O''Reilly Media', 2017, 189900.00, 18, NULL),
  ('00000000-0000-4000-9000-000000000002', '9781098115784', 'Designing Machine Learning Systems', 'Chip Huyen', 'An iterative framework for designing production-ready machine learning systems.', 'Machine Learning', 'O''Reilly Media', 2022, 174900.00, 15, NULL),
  ('00000000-0000-4000-9000-000000000003', '9781492052203', 'Building Machine Learning Powered Applications', 'Emmanuel Ameisen', 'A practical path from a machine learning idea to a deployed application.', 'Machine Learning', 'O''Reilly Media', 2020, 159900.00, 12, NULL),
  ('00000000-0000-4000-9000-000000000004', '9781617294433', 'Machine Learning Engineering', 'Andriy Burkov', 'Engineering principles for building and operating machine learning solutions.', 'Machine Learning', 'Manning', 2020, 149900.00, 10, NULL),
  ('00000000-0000-4000-9000-000000000005', '9780132350884', 'Clean Code', 'Robert C. Martin', 'Principles and practices for writing maintainable software.', 'Software Engineering', 'Prentice Hall', 2008, 139900.00, 22, NULL),
  ('00000000-0000-4000-9000-000000000006', '9780201616224', 'The Pragmatic Programmer', 'Andrew Hunt and David Thomas', 'Practical approaches to software development and professional engineering.', 'Software Engineering', 'Addison-Wesley', 1999, 129900.00, 16, NULL),
  ('00000000-0000-4000-9000-000000000007', '9780131103627', 'The C Programming Language', 'Brian W. Kernighan and Dennis M. Ritchie', 'A concise introduction to the C programming language.', 'Programming', 'Prentice Hall', 1988, 119900.00, 9, NULL),
  ('00000000-0000-4000-9000-000000000008', '9780262046305', 'Introduction to Algorithms', 'Thomas H. Cormen et al.', 'A comprehensive reference on algorithms and data structures.', 'Computer Science', 'MIT Press', 2022, 249900.00, 7, NULL),
  ('00000000-0000-4000-9000-000000000009', '9781449373320', 'Designing Distributed Systems', 'Brendan Burns', 'Patterns and paradigms for building reliable distributed systems.', 'Distributed Systems', 'O''Reilly Media', 2018, 144900.00, 13, NULL),
  ('00000000-0000-4000-9000-000000000010', '9781492078005', 'Fundamentals of Data Engineering', 'Joe Reis and Matt Housley', 'Concepts and practices across the data engineering lifecycle.', 'Data Engineering', 'O''Reilly Media', 2022, 179900.00, 19, NULL),
  ('00000000-0000-4000-9000-000000000011', '9781098107963', 'Fundamentals of Software Architecture', 'Mark Richards and Neal Ford', 'An engineering approach to software architecture characteristics and trade-offs.', 'Software Architecture', 'O''Reilly Media', 2020, 169900.00, 14, NULL),
  ('00000000-0000-4000-9000-000000000012', '9780134494166', 'Clean Architecture', 'Robert C. Martin', 'Architectural principles for creating maintainable software systems.', 'Software Architecture', 'Pearson', 2017, 154900.00, 11, NULL)
ON CONFLICT (isbn) DO NOTHING;
