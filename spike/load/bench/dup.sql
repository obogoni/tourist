-- Keys shared by all clients from a pool of :dpool, each key always with the same
-- request, so concurrent duplicates race on the key while in flight.
\set r random(1, :dpool)
\set i abs(hash(:r + :run * 1000000)) % :nw
\set t mod(:i, :nt) + 1
\set amt 100 + abs(hash(:r, 7)) % 4900
SELECT payment(:t::int, 1000000 + :i::bigint, :amt::bigint, md5(concat('dup-', :run::int, '-', :r::int))::uuid::text);
