\set i random(0, :nw - 1)
\set w 1000000 + :i
\set t mod(:i, :nt) + 1
\set m :t * 10 + random(1, 2)
\set amt random(1000, 20000)
\set n :n + 1
SELECT topup(:t::int, :w::bigint, :m::int, :amt::bigint, md5(concat(:run::int, '-', :client_id::int, '-', :n::int))::uuid::text);
