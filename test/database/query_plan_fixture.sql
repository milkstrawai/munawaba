-- Isolated, deterministic release-scale fixture; never load into a host database.
INSERT INTO munawaba_people (id,name,email,active,lock_version,created_at,updated_at)
SELECT n,'Person '||n,'person'||n||'@example.org',true,0,'2026-09-05 12:00Z','2026-09-05 12:00Z' FROM generate_series(1,1000) n;
INSERT INTO munawaba_schedules (id,name,state,cadence,time_zone,anchor_local_date,anchor_local_seconds,first_activated_at,coverage_revision,coverage_start_boundary,coverage_starts_at,generated_through_boundary,rotation_revision,rotation_effective_boundary,pause_effective_at,lifecycle_revision,notification_revision,slack_enabled,notify_advance,advance_notice_seconds,notify_shift_start,notify_assignment_change,notify_next_assignment_change,lock_version,created_at,updated_at)
SELECT n,'Schedule '||n,CASE WHEN n<=10 THEN 'scheduled' WHEN n<=20 THEN 'pausing' ELSE 'active' END,'one_week','UTC','2018-01-20',43200,
CASE WHEN n<=10 THEN NULL ELSE '2018-01-20 12:00Z'::timestamptz END,1,0,
CASE WHEN n<=10 THEN '2026-09-05 12:00Z'::timestamptz+(n-5)*interval '1 hour' ELSE '2018-01-20 12:00Z'::timestamptz END,499,1,CASE WHEN n BETWEEN 11 AND 20 THEN NULL ELSE 0 END,
CASE WHEN n BETWEEN 11 AND 20 THEN '2026-09-05 12:00Z'::timestamptz+(n-15)*interval '1 hour' ELSE NULL END,1,2,false,true,86400,true,true,true,0,'2026-09-05 12:00Z','2026-09-05 12:00Z'
FROM generate_series(1,200) n;
INSERT INTO munawaba_schedule_memberships (schedule_id,person_id,position,created_at,updated_at)
SELECT s,((s-1)*5+p)%1000+1,p,'2026-09-05 12:00Z','2026-09-05 12:00Z' FROM generate_series(1,200) s CROSS JOIN generate_series(0,4) p;
INSERT INTO munawaba_shifts (id,schedule_id,coverage_revision,boundary_index,starts_at,ends_at,base_person_id,effective_person_id,rotation_revision,assignment_version,timing_version,canceled_at,cancellation_reason,generated_at,lock_version,created_at,updated_at)
SELECT (s-1)*500+b+1,s,1,b,'2018-01-20 12:00Z'::timestamptz+b*interval '1 week','2018-01-20 12:00Z'::timestamptz+(b+1)*interval '1 week',((s-1)*5+b%5)%1000+1,((s-1)*5+b%5)%1000+1,1,1,1,
CASE WHEN b<25 THEN '2018-01-20 12:00Z'::timestamptz ELSE NULL END,CASE WHEN b<25 THEN 'pause' ELSE NULL END,'2018-01-20 12:00Z',0,'2018-01-20 12:00Z','2018-01-20 12:00Z'
FROM generate_series(1,200) s CROSS JOIN generate_series(0,499) b;
INSERT INTO munawaba_shift_overrides (shift_id,previous_person_id,replacement_person_id,created_at,updated_at)
SELECT id,base_person_id,(base_person_id+99)%1000+1,'2026-09-05 12:00Z','2026-09-05 12:00Z' FROM munawaba_shifts WHERE boundary_index BETWEEN 450 AND 454;
INSERT INTO munawaba_notification_deliveries (id,schedule_id,shift_id,kind,status,event_key,coverage_revision,assignment_version,timing_version,notification_revision,context,due_at,next_attempt_at,expires_at,claim_token,enqueued_at,processing_at,lease_expires_at,last_attempt_at,attempt_count,last_http_status,last_error_code,delivered_at,created_at,updated_at)
SELECT n,(n-1)%200+1,CASE WHEN n%5=0 THEN NULL ELSE ((n-1)%200)*500+(n%500)+1 END,
CASE WHEN n%5=0 THEN 'test' ELSE 'shift_start' END,
CASE WHEN ((n-1)/200)%1000<8 THEN 'pending' WHEN ((n-1)/200)%1000<10 THEN 'enqueued' WHEN ((n-1)/200)%1000<12 THEN 'processing' WHEN ((n-1)/200)%1000<700 THEN 'delivered' WHEN ((n-1)/200)%1000<850 THEN 'stale' WHEN ((n-1)/200)%1000<950 THEN 'canceled' ELSE 'failed' END,
'fixture:'||n,CASE WHEN n%5=0 THEN NULL ELSE 1 END,CASE WHEN n%5=0 THEN NULL ELSE 1 END,CASE WHEN n%5=0 THEN NULL ELSE 1 END,1,'{"schema_version":1}'::jsonb,
'2026-09-05 10:00Z',CASE WHEN ((n-1)/200)%1000<8 THEN '2026-09-05 12:00Z'::timestamptz+((n%2000)-1000)*interval '1 second' ELSE NULL END,
'2026-09-05 12:00Z'::timestamptz+((n%4000)-1000)*interval '1 second',
CASE WHEN ((n-1)/200)%1000 BETWEEN 8 AND 11 THEN ('00000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid ELSE NULL END,
CASE WHEN ((n-1)/200)%1000 BETWEEN 8 AND 11 THEN '2026-09-05 11:00Z'::timestamptz ELSE NULL END,
CASE WHEN ((n-1)/200)%1000 BETWEEN 10 AND 11 THEN '2026-09-05 11:01Z'::timestamptz ELSE NULL END,
CASE WHEN ((n-1)/200)%1000 BETWEEN 8 AND 11 THEN '2026-09-05 12:00Z'::timestamptz+((n%4000)-1000)*interval '1 second' ELSE NULL END,
CASE WHEN ((n-1)/200)%1000>=10 THEN '2026-09-05 11:01Z'::timestamptz ELSE NULL END,
CASE WHEN ((n-1)/200)%1000>=10 THEN 1 ELSE 0 END,
CASE WHEN ((n-1)/200)%1000 BETWEEN 12 AND 699 THEN 200 ELSE NULL END,
CASE WHEN ((n-1)/200)%1000>=950 THEN 'delivery_outcome_unknown' ELSE NULL END,
CASE WHEN ((n-1)/200)%1000 BETWEEN 12 AND 699 THEN '2026-09-05 11:01Z'::timestamptz ELSE NULL END,
'2026-09-05 12:00Z'::timestamptz-n*interval '1 minute','2026-09-05 12:00Z'::timestamptz-n*interval '1 minute'
FROM generate_series(1,250000) n;
INSERT INTO munawaba_audit_events (id,operation_id,event_type,schedule_id,person_id,shift_id,actor_type,actor_id,actor_name,metadata,occurred_at,created_at)
SELECT n,('00000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
CASE WHEN n%2=0 THEN 'person.created' ELSE 'schedule.updated' END,(n-1)%200+1,(n-1)%1000+1,(n-1)%100000+1,'User',((n-1)%50+1)::text,'Administrator',
CASE WHEN n%2=0 THEN '{"schema_version":1,"source":"human","active":true,"slack_member_configured":false}'::jsonb ELSE '{"schema_version":1,"source":"human","changed_fields":["name"],"before":{"name":"Old name"},"after":{"name":"New name"}}'::jsonb END,
'2026-09-05 12:00Z'::timestamptz-n*interval '1 minute','2026-09-05 12:00Z'::timestamptz-n*interval '1 minute'
FROM generate_series(1,250000) n;
ANALYZE;
