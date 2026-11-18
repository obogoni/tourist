\set i :nw
\set t mod(:i, :nt) + 1
\set n :n + 1
SELECT topup(:t::int, 1000000 + :i::bigint, :t::int * 10 + 1, 100, md5(concat(:run::int, '-', :client_id::int, '-', :n::int))::uuid::text);
