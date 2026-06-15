/*******************************************************************************
   Chinook Oracle — schema/user setup (run as SYSTEM)
   Creates the 'chinook' Oracle user. DDL + data are loaded separately from
   the official Chinook dataset (downloaded at postCreateCommand time).
********************************************************************************/

-- Idempotent: drop and recreate so the script can be re-run cleanly
BEGIN
  EXECUTE IMMEDIATE 'DROP USER chinook CASCADE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
CREATE USER chinook IDENTIFIED BY chinook;

-- Privileges required by the official Chinook data script + yb-voyager
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW,
      UNLIMITED TABLESPACE, SELECT ANY DICTIONARY TO chinook;
