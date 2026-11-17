-- The batch wallet (70 writes/s in the reference data).
\set i :nw
\set t mod(:i, :nt) + 1
\set n :n + 1
SELECT payment(:t::int, 1000000 + :i::bigint, 100, md5(concat(:run::int, '-', :client_id::int, '-', :n::int))::uuid::text);
