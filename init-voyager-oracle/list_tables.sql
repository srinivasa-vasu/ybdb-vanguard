SET PAGESIZE 100
SELECT table_name FROM all_tables WHERE owner = USER ORDER BY table_name;
EXIT;
