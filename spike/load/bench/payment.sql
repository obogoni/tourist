-- Organic payment on a random wallet; remembers it for retry.sql and reversal.sql.
\set i random(0, :nw - 1)
\set w 1000000 + :i
\set t mod(:i, :nt) + 1
\set amt random(100, 5000)
\set n :n + 1
SELECT (payment(:t::int, :w::bigint, :amt::bigint, md5(concat(:run::int, '-', :client_id::int, '-', :n::int))::uuid::text))->>'operation_id' AS last_op \gset
\set pt :t
\set pw :w
\set pamt :amt
\set pn :n
