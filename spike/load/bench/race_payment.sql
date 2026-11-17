-- 20 wallets with credit_limit 1000: concurrent payments near the limit.
\set i :nw + random(1, 20)
\set t mod(:i, :nt) + 1
\set n :n + 1
SELECT payment(:t::int, 1000000 + :i::bigint, 400, md5(concat(:run::int, '-', :client_id::int, '-', :n::int))::uuid::text);
