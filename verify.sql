-- verify.sql
-- Checks that performance_schema is properly installed
-- Note: table sizes are shown separately by verify.sh

SELECT 'schema_exists' AS check_name,
       CASE WHEN EXISTS (
         SELECT 1 FROM pg_namespace WHERE nspname = 'performance_schema'
       ) THEN 'yes' ELSE 'no' END AS value;

SELECT p.proname AS function_name
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'performance_schema'
ORDER BY p.proname;

SELECT c.relname AS view_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'performance_schema'
  AND c.relkind = 'v'
ORDER BY c.relname;
