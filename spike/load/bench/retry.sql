-- Retries this client's last payment with the same key and request.
SELECT payment(:pt::int, :pw::bigint, :pamt::bigint, md5(concat(:run::int, '-', :client_id::int, '-', :pn::int))::uuid::text);
