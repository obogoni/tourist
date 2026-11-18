-- Two wallets of one customer: same residue modulo the number of customers.
\set i random(0, :nw - 1)
\set j mod(:i + :nt * random(1, 1000), :nw)
\set t mod(:i, :nt) + 1
\set amt random(100, 3000)
\set n :n + 1
SELECT transfer(:t::int, 1000000 + :i::bigint, 1000000 + :j::bigint, :amt::bigint, md5(concat(:run::int, '-', :client_id::int, '-', :n::int))::uuid::text);
