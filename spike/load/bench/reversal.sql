-- Reverses this client's last payment (rejected if already reversed or never completed).
\set n :n + 1
SELECT reversal(:pt::int, :last_op::bigint, md5(concat(:run::int, '-', :client_id::int, '-', :n::int))::uuid::text);
