CREATE TABLE IF NOT EXISTS public.dept (
  deptno integer NOT NULL,
  dname text,
  loc text,
  description text,
  CONSTRAINT pk_dept PRIMARY KEY (deptno asc)
);

CREATE TABLE IF NOT EXISTS emp (
  empno integer generated by default as identity (start with 10000) NOT NULL,
  ename text NOT NULL,
  job text,
  mgr integer,
  hiredate date,
  sal integer,
  comm integer,
  deptno integer NOT NULL,
  email text,
  other_info jsonb,
  CONSTRAINT pk_emp PRIMARY KEY (empno hash),
  CONSTRAINT emp_email_uk UNIQUE (email),
  CONSTRAINT fk_deptno FOREIGN KEY (deptno) REFERENCES dept(deptno),
  CONSTRAINT fk_mgr FOREIGN KEY (mgr) REFERENCES emp(empno),
  CONSTRAINT emp_email_check CHECK (
    (
      email ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'::text
    )
  )
);

-- dept
INSERT INTO dept (deptno, dname, loc, description)
VALUES (
    10,
    'ACCOUNTING',
    'NEW YORK',
    'preparation of financial statements, maintenance of general ledger, payment of bills, preparation of customer bills, payroll, and more.'
  ),
  (
    20,
    'RESEARCH',
    'DALLAS',
    'responsible for preparing the substance of a research report or security recommendation.'
  ),
  (
    30,
    'SALES',
    'CHICAGO',
    'division of a business that is responsible for selling products or services'
  ),
  (
    40,
    'OPERATIONS',
    'BOSTON',
    'administration of business practices to create the highest level of efficiency possible within an organization'
  );

-- emp
INSERT INTO emp (
    empno,
    ename,
    job,
    mgr,
    hiredate,
    sal,
    comm,
    deptno,
    email,
    other_info
  )
VALUES (
    7369,
    'SMITH',
    'CLERK',
    7902,
    '1980-12-17',
    800,
    NULL,
    20,
    'SMITH@acme.com',
    '{"skills":["accounting"]}'
  ),
  (
    7499,
    'ALLEN',
    'SALESMAN',
    7698,
    '1981-02-20',
    1600,
    300,
    30,
    'ALLEN@acme.com',
    null
  ),
  (
    7521,
    'WARD',
    'SALESMAN',
    7698,
    '1981-02-22',
    1250,
    500,
    30,
    'WARD@compuserve.com',
    null
  ),
  (
    7566,
    'JONES',
    'MANAGER',
    7839,
    '1981-04-02',
    2975,
    NULL,
    20,
    'JONES@gmail.com',
    null
  ),
  (
    7654,
    'MARTIN',
    'SALESMAN',
    7698,
    '1981-09-28',
    1250,
    1400,
    30,
    'MARTIN@acme.com',
    null
  ),
  (
    7698,
    'BLAKE',
    'MANAGER',
    7839,
    '1981-05-01',
    2850,
    NULL,
    30,
    'BLAKE@hotmail.com',
    null
  ),
  (
    7782,
    'CLARK',
    'MANAGER',
    7839,
    '1981-06-09',
    2450,
    NULL,
    10,
    'CLARK@acme.com',
    '{"skills":["C","C++","SQL"]}'
  ),
  (
    7788,
    'SCOTT',
    'ANALYST',
    7566,
    '1982-12-09',
    3000,
    NULL,
    20,
    'SCOTT@acme.com',
    '{"cat":"tiger"}'
  ),
  (
    7839,
    'KING',
    'PRESIDENT',
    NULL,
    '1981-11-17',
    5000,
    NULL,
    10,
    'KING@aol.com',
    null
  ),
  (
    7844,
    'TURNER',
    'SALESMAN',
    7698,
    '1981-09-08',
    1500,
    0,
    30,
    'TURNER@acme.com',
    null
  ),
  (
    7876,
    'ADAMS',
    'CLERK',
    7788,
    '1983-01-12',
    1100,
    NULL,
    20,
    'ADAMS@acme.org',
    null
  ),
  (
    7900,
    'JAMES',
    'CLERK',
    7698,
    '1981-12-03',
    950,
    NULL,
    30,
    'JAMES@acme.org',
    null
  ),
  (
    7902,
    'FORD',
    'ANALYST',
    7566,
    '1981-12-03',
    3000,
    NULL,
    20,
    'FORD@acme.com',
    '{"skills":["SQL","CQL"]}'
  ),
  (
    7934,
    'MILLER',
    'CLERK',
    7782,
    '1982-01-23',
    1300,
    NULL,
    10,
    'MILLER@acme.com',
    null
  );