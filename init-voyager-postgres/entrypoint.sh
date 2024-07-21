#!/bin/bash

# Set wal_level to 'logical'
sed -i 's/^#*wal_level .*$/wal_level = logical/' /var/lib/postgresql/data/postgresql.conf

# Start PostgreSQL server
exec postgres